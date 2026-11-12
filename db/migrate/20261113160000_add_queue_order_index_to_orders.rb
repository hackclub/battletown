# The staff order queue (/admin/orders) sorts every order by an expression: requested, then on hold, then shipped, then the rest,
# newest first (Order.queue_order). Without an index that is a scan and sort of the whole table (about 45 ms at 100,000 orders, growing
# with the table); this expression index lets it read just the first 200 rows. The expression must match the scope's exactly.
# Built CONCURRENTLY so a live table is never locked; reversible.
class AddQueueOrderIndexToOrders < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :orders,
              "(CASE status WHEN 'requested' THEN 0 WHEN 'on_hold' THEN 1 WHEN 'shipped' THEN 2 ELSE 3 END), created_at DESC, id DESC",
              name: "index_orders_on_queue_order", algorithm: :concurrently
  end
end
