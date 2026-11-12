module Orders
  # Staff marks an order handed over, from `requested` or from `shipped`. Idempotent: an order that is already fulfilled is
  # returned unchanged and keeps its first fulfilled_at. Queues the buyer's "fulfilled" message once.
  class Fulfil < Transition
    private

    def action = "fulfil"

    def refusal = "That order can't be marked fulfilled."
  end
end
