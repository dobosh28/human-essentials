# Provides Full CRUD+ for Storage Locations, which are digital representations of inventory holdings
class StorageLocationsController < ApplicationController
  include Importable

  Struct.new('OmittedInventoryItem', :item) do
    def quantity
      0
    end
  end

  def index
    @selected_item_category = filter_params[:containing]
    @items = current_organization.storage_locations.items_inventoried
    @include_inactive_storage_locations = params[:include_inactive_storage_locations].present?
    @storage_locations = current_organization.storage_locations.alphabetized.class_filter(filter_params)

    unless @include_inactive_storage_locations
      @storage_locations = @storage_locations.kept
    end

    active_inventory_item_names = []
    @storage_locations.each do |storage_location|
      active_inventory_item_names <<
        storage_location
        .active_inventory_items
        .joins(:item)
        .select('distinct items.name')
        .pluck(:name)
    end
    active_inventory_item_names = active_inventory_item_names.flatten.uniq.sort

    respond_to do |format|
      format.html
      format.csv { send_data StorageLocation.generate_csv(@storage_locations, active_inventory_item_names), filename: "StorageLocations-#{Time.zone.today}.csv" }
    end
  end

  def create
    @storage_location = current_organization.storage_locations.new(storage_location_params)
    if @storage_location.save
      redirect_to storage_locations_path, notice: "New storage location added!"
    else
      flash[:error] = "Something didn't work quite right -- try again?"
      render action: :new
    end
  end

  def new
    @storage_location = current_organization.storage_locations.new
  end

  def edit
    @storage_location = current_organization.storage_locations.find(params[:id])
  end

  # TODO: Move these queries to Query Object
  def show
    @storage_location = current_organization.storage_locations.find(params[:id])
    # TODO: Find a way to do these with less hard SQL. These queries have to be manually updated because they're not in-sync with the Model
    @items_out = ItemsOutQuery.new(organization: current_organization, storage_location: @storage_location).call
    @items_out_total = ItemsOutTotalQuery.new(organization: current_organization, storage_location: @storage_location).call
    @items_in = ItemsInQuery.new(organization: current_organization, storage_location: @storage_location).call
    @items_in_total = ItemsInTotalQuery.new(organization: current_organization, storage_location: @storage_location).call

    respond_to do |format|
      format.html
      format.csv { send_data @storage_location.to_csv }
      format.xls
    end
  end

  def import_inventory
    if params[:file].nil?
      redirect_back(fallback_location: storage_locations_path(organization_id: current_organization))
      flash[:error] = "No file was attached!"
    else
      filepath = params[:file].read
      StorageLocation.import_inventory(filepath, current_organization.id, params[:storage_location])
      flash[:notice] = "Inventory imported successfully!"
      redirect_back(fallback_location: storage_locations_path(organization_id: current_organization))
    end
  end

  def update
    @storage_location = current_organization.storage_locations.find(params[:id])
    if @storage_location.update(storage_location_params)
      redirect_to storage_locations_path, notice: "#{@storage_location.name} updated!"
    else
      flash[:error] = "Something didn't work quite right -- try again?"
      render action: :edit
    end
  end

  def deactivate
    @storage_location = current_organization.storage_locations.kept.find(params[:storage_location_id])
    svc = StorageLocationDeactivateService.new(storage_location: @storage_location)
    if svc.call
      redirect_to storage_locations_path, notice: "Storage Location deactivated successfully"
    else
      redirect_back(fallback_location: storage_locations_path(organization_id: current_organization),
        error: "Cannot deactivate storage location containing inventory items with non-zero quantities")
    end
  end

  def reactivate
    @storage_location = current_organization.storage_locations.all.find(params[:storage_location_id])
    if @storage_location.undiscard!
      redirect_to storage_locations_path, notice: "Storage Location reactivated successfully"
    else
      redirect_back(fallback_location: storage_locations_path(organization_id: current_organization), error: "Something didn't work quite right -- try again?")
    end
  end

  def destroy
    @storage_location = current_organization.storage_locations.find(params[:id])

    if @storage_location.destroy
      redirect_to storage_locations_path, notice: "Storage Location deleted successfully"
    else
      flash[:error] = @storage_location.errors.full_messages.join(', ')
      redirect_to storage_locations_path
    end
  end

  def inventory
    @inventory_items = current_organization.storage_locations
                                           .includes(inventory_items: :item)
                                           .find(params[:id])
                                           .inventory_items

    @inventory_items = @inventory_items.active unless params[:include_inactive_items] == "true"
    @inventory_items += include_omitted_items(@inventory_items.collect(&:item_id)) if params[:include_omitted_items] == "true"

    respond_to :json
  end

  private

  def storage_location_params
    params.require(:storage_location).permit(:name, :address, :square_footage, :warehouse_type, :time_zone)
  end

  def include_omitted_items(existing_item_ids = [])
    current_organization.items.where.not(id: existing_item_ids).collect do |item|
      Struct::OmittedInventoryItem.new(item)
    end
  end

  helper_method \
    def filter_params
    return {} unless params.key?(:filters)

    params.require(:filters).permit(:containing)
  end
end
