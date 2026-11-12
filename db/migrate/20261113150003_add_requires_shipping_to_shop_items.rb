# Whether an item is posted to the buyer, and so needs a delivery address at checkout. True for everything that exists today
# (the sticker, the T-shirt, the pins ...); staff clear it in /admin/shop for an item with nothing to post.
class AddRequiresShippingToShopItems < ActiveRecord::Migration[8.1]
  def change
    add_column :shop_items, :requires_shipping, :boolean, default: true, null: false
  end
end
