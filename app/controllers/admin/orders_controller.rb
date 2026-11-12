module Admin
  # The staff order queue and one order's page. The queue shows requested orders first, with a tab per status (and its count), a
  # search by item name or order number, the age of each order and an "Overdue" chip. The order page has its history, staff notes
  # and only the actions that are legal for its status (hold, release, ship, fulfil, cancel, refund, tracking, note); each is an
  # Orders::* service call under the row locks, so a double click or a second admin changes nothing twice. Cancel and refund ask
  # for a reason code and a typed confirmation. The CSV export is a POST (Orders::CsvExport), audited, capped and streamed.
  # Shows the person's display name, Slack id and verification status (staff need them to arrange delivery over Slack); no
  # address exists anywhere in this app.
  class OrdersController < BaseController
    LIMIT = 200
    SEARCH_MAX = 60
    TABS = Order::STATUSES
    CONFIRM_WORDS = { "cancel" => "cancel", "refund" => "refund" }.freeze
    NOTICES = { hold: "Put on hold. The buyer still sees Requested.", release: "Taken off hold.", ship: "Marked shipped.", fulfil: "Marked fulfilled.",
                cancel: "Cancelled.", refund: "Refunded.", note: "Note added.", tracking: "Tracking saved." }.freeze

    before_action :set_order, only: %i[show hold release ship fulfil cancel refund tracking note]

    def index
      @filters = filters
      @counts = Order.group(:status).count
      @orders = filtered(Order.all).includes(:user).queue_order.limit(LIMIT).to_a
      @waiting_count = @counts.fetch("requested", 0)
      @on_hold_count = @counts.fetch("on_hold", 0)
    end

    def show
      @events = @order.events.includes(:actor).newest_first.to_a
      @actions = Orders::StateMachine.actions_for(@order.status, "staff")
    end

    def hold = act(:hold) { |order| Orders::Hold.call(**args(order)) }

    def release = act(:release) { |order| Orders::Release.call(**args(order)) }

    def fulfil = act(:fulfil) { |order| Orders::Fulfil.call(**args(order)) }

    def ship = act(:ship) { |order| Orders::Ship.call(**args(order), tracking: tracking_params) }

    def cancel = act(:cancel, confirm: true) { |order| Orders::Cancel.call(**args(order)) }

    def refund = act(:refund, confirm: true) { |order| Orders::Refund.call(**args(order)) }

    def tracking = act(:tracking) { |order| Orders::UpdateTracking.call(order: order, by: current_user, tracking: tracking_params) }

    def note = act(:note) { |order| Orders::AddNote.call(order: order, by: current_user, note: text(:note)) }

    # POST, not GET: an export is a bulk read of personal-adjacent data, so it needs the CSRF token, and the audit row is written
    # before the first byte is sent.
    def export
      export = Orders::CsvExport.new(scope: filtered(Order.all).queue_order, include_contact: params[:include_contact] == "1")
      AdminAudit.record!(actor: current_user, action: "order_exported", subject: [ "orders", 0 ],
                         metadata: export.audit_metadata(filters).compact)
      response.headers["Content-Type"] = "text/csv; charset=utf-8"
      response.headers["Content-Disposition"] = %(attachment; filename="orders-#{Time.current.utc.strftime('%Y%m%d-%H%M')}.csv")
      response.headers["Last-Modified"] = Time.current.httpdate # no buffering by the ETag middleware
      response.headers["X-Accel-Buffering"] = "no"
      self.response_body = export.each_line
    end

    private

    def set_order = @order = Order.includes(:user).find(params[:id])

    def args(order) = { order: order, by: current_user, as: :staff, reason_code: text(:reason_code), note: text(:note) }

    # One shape for every write: check the typed confirmation where one is needed, call the service, say what happened.
    def act(name, confirm: false)
      return redirect_to(admin_order_path(@order), alert: "Type #{CONFIRM_WORDS.fetch(name.to_s).upcase} in the box to confirm.", status: :see_other) if confirm && !confirmed?(name)

      result = yield @order
      redirect_to admin_order_path(@order), notice: result.changed? ? NOTICES.fetch(name) : "Nothing changed: the order was already there.", status: :see_other
    rescue Shop::Error => error
      redirect_to admin_order_path(@order), alert: error.message, status: :see_other
    end

    def confirmed?(name) = text(:confirm).strip.casecmp?(CONFIRM_WORDS.fetch(name.to_s))

    def tracking_params
      raw = params[:tracking]
      return {} unless raw.respond_to?(:permit)

      raw.permit(:carrier, :number, :label).to_h.transform_values { |value| value.is_a?(String) ? value : "" }
    end

    # Only whitelisted values survive (anything else, arrays and hashes included, falls back to "no filter").
    def filters
      { status: text(:status).presence_in(Order::STATUSES), kind: text(:kind).presence_in(Order::KINDS), q: text(:q).squish.first(SEARCH_MAX).presence }
    end

    def filtered(scope)
      current = filters
      scope = scope.where(status: current[:status]) if current[:status]
      scope = scope.where(kind: current[:kind]) if current[:kind]
      scope = search(scope, current[:q]) if current[:q]
      scope
    end

    # The item name (a substring, case-insensitive) or the order number. Never a person: no name, email or Slack id is searched.
    def search(scope, term)
      like = Order.where("prize_name ILIKE ?", "%#{Order.sanitize_sql_like(term)}%")
      number = term.delete_prefix("#")
      number.match?(/\A\d{1,12}\z/) ? scope.merge(like.or(Order.where(id: number.to_i))) : scope.merge(like)
    end

    def text(name) = params[name].is_a?(String) ? params[name] : ""
  end
end
