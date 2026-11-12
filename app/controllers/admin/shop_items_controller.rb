module Admin
  # The shop catalogue for staff (/admin/shop): list (active and archived tabs, in shop order), add, edit, archive and restore,
  # move up and down. Items are found by key, the key and kind are set once, and nothing is ever deleted: archiving hides an
  # item from the shop, landing page and prize picker while orders and picks that name it stay valid. Prices are coins only.
  #
  # Pictures go through the same safe re-encode as ship screenshots (ShipImages::Processor with ShopItems::Config). Two admins
  # saving the same item at once are caught by `lock_version` (the second sees "someone else changed this"). The page shows
  # aggregates only (orders by status, how many people picked an item): no names. Every change is recorded in the staff audit trail (AdminAudit), in the same transaction as the change.
  class ShopItemsController < BaseController
    before_action :set_item, only: %i[edit update archive restore move]

    def index
      @view = params[:view] == "archived" ? "archived" : "active"
      everything = ShopItem.without_content.in_order.to_a
      @counts = { "active" => everything.count(&:active), "archived" => everything.count { |item| !item.active } }
      @items = everything.select { |item| item.active == (@view == "active") }
      @empty = everything.empty?
      @orders = Order.group(:prize_key, :status).count
      @picks = User.where.not(prize_key: nil).group(:prize_key).count
    end

    def new
      @item = ShopItem.new(coins: 10, tier: "shop", kind: "regular", active: true, position: next_position)
    end

    def create
      @item = ShopItem.new(create_params)
      @item.position = next_position if @item.position.nil?
      problem = apply_picture
      if problem.nil? && save_item { audit("shop_item_created", coins: @item.coins, kind: @item.kind, active: @item.active, picture: @item.image?) }
        redirect_to admin_shop_items_path, notice: "Added #{@item.name}.", status: :see_other
      else
        report(problem)
        render :new, status: :unprocessable_content
      end
    end

    def edit
      load_stats
    end

    def update
      @item.assign_attributes(update_params)
      problem = apply_picture
      changed = []
      if problem.nil? && save_item { changed = audit_update }
        redirect_to admin_shop_items_path(view: view_of(@item)), notice: (changed.any? ? "Saved #{@item.name}." : "Nothing to change on #{@item.name}."), status: :see_other
      else
        report(problem)
        load_stats
        render :edit, status: :unprocessable_content
      end
    rescue ActiveRecord::StaleObjectError
      redirect_to admin_edit_shop_item_path(@item.key), alert: "Someone else changed #{@item.name_was} while you were editing. The form now shows their version: make your change again.", status: :see_other
    end

    def archive
      set_active(false, "shop_item_archived", "Archived #{@item.name}. It is hidden from the shop, the landing page and the prize picker; orders and picks that name it still work.")
    end

    def restore
      set_active(true, "shop_item_restored", "Restored #{@item.name}. It is back in the shop, on the landing page and in the prize picker.")
    end

    def move
      direction = params[:direction].to_s
      return redirect_to(admin_shop_items_path(view: view_of(@item)), alert: "That wasn't a direction.", status: :see_other) unless ShopItems::Reorder::DIRECTIONS.include?(direction)

      moved = ShopItem.transaction do
        ShopItems::Reorder.call(key: @item.key, direction: direction).tap { |did_move| audit("shop_item_reordered", direction: direction) if did_move }
      end
      redirect_to admin_shop_items_path(view: view_of(@item), anchor: "item-#{@item.key}"), status: :see_other,
                  notice: (moved ? "Moved #{@item.name} #{direction}." : "#{@item.name} is already at the #{direction == 'up' ? 'top' : 'bottom'}.")
    end

    private

    def set_item = @item = ShopItem.find_by!(key: params[:key])

    def view_of(item) = item.active ? "active" : "archived"

    def next_position = ShopItem.maximum(:position).to_i + 1

    def item_params = params.expect(shop_item: %i[name description emoji coins tier position lock_version])

    # The key and the kind are chosen once, here, and never again. A free signup item is only offered while none exists.
    def create_params
      permitted = params.expect(shop_item: %i[key kind name description emoji coins tier position active])
      attributes = permitted.to_h.symbolize_keys
      attributes[:key] = attributes[:key].to_s.strip
      attributes[:kind] = "regular" unless ShopItem::KINDS.include?(attributes[:kind])
      attributes[:active] = ActiveModel::Type::Boolean.new.cast(attributes[:active])
      attributes.except(:coins).merge(coins: attributes[:kind] == "free_signup" ? 0 : attributes[:coins])
    end

    def update_params
      attributes = item_params.to_h.symbolize_keys
      attributes[:coins] = 0 if @item.free_signup?
      attributes
    end

    # The picture field: a new upload replaces the picture, "Remove the picture" clears it. Returns the reason in words when the
    # upload cannot be used (nothing is saved then), nil otherwise.
    def apply_picture
      fields = params[:shop_item]
      return unless fields.respond_to?(:key?)

      upload = fields[:image]
      if upload.present?
        return "That wasn't a file we could read." unless upload.respond_to?(:tempfile)

        @item.attach_image(ShipImages::Processor.call(upload, config: ShopItems::Config.current))
      elsif fields[:remove_image] == "1"
        @item.remove_image
      end
      nil
    rescue ShipImages::Rejected => error
      error.message
    end

    def report(problem)
      @item.valid?
      @item.errors.add(:base, "The picture: #{problem}") if problem
    end

    def set_active(value, action, message)
      if @item.active == value
        redirect_to admin_shop_items_path(view: view_of(@item)), notice: "#{@item.name} was already #{value ? 'in the shop' : 'archived'}.", status: :see_other
        return
      end

      ShopItem.transaction do
        @item.update!(active: value)
        audit(action)
      end
      redirect_to admin_shop_items_path(view: view_of(@item)), notice: message, status: :see_other
    rescue ActiveRecord::StaleObjectError
      redirect_to admin_shop_items_path(view: view_of(@item)), alert: "Someone else changed #{@item.name} just now. Check it and try again.", status: :see_other
    end

    def load_stats
      @picks = User.where(prize_key: @item.key).count
      @orders = Order.where(prize_key: @item.key).group(:status).count
    end

    # Saves the item and runs the block (which writes the audit row) in one transaction, so the change and its trail commit or
    # roll back together. False when the item is invalid.
    def save_item
      ShopItem.transaction do
        raise ActiveRecord::Rollback unless @item.save

        yield
        true
      end
    end

    # The audit row for an edit: which fields changed and the coin price before and after. Returns the changed field names.
    def audit_update
      saved = @item.saved_changes
      changed = saved.keys - %w[updated_at lock_version image_width image_height image_byte_size image_sha256]
      changed = changed.map { |name| name == "image_content" ? "picture" : name }
      return changed if changed.empty?

      details = { changed: changed.join(" ") }
      details.merge!(coins_before: saved["coins"].first, coins_after: saved["coins"].last) if saved.key?("coins")
      audit("shop_item_updated", **details)
      changed
    end

    # Only field names, coin prices and flags: nothing about a person.
    def audit(action, **metadata)
      AdminAudit.record!(actor: current_user, action: action, subject: @item, metadata: metadata)
    end
  end
end
