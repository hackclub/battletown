# Stands in for the staff audit log (AdminAudit) so a test can see exactly what was recorded, whether or not the real one
# exists yet. install_audit_spy swaps the constant for a recorder and remove_audit_spy puts the original back.
module AdminAuditSpy
  Call = Struct.new(:actor, :action, :subject, :metadata)

  def install_audit_spy
    @audit_calls = []
    calls = @audit_calls
    @original_admin_audit = Object.const_get(:AdminAudit) if Object.const_defined?(:AdminAudit)
    Object.send(:remove_const, :AdminAudit) if Object.const_defined?(:AdminAudit, false)
    spy = Module.new do
      define_singleton_method(:record!) { |actor:, action:, subject:, metadata: {}| calls << Call.new(actor, action, subject, metadata) }
    end
    Object.const_set(:AdminAudit, spy)
  end

  def remove_audit_spy
    Object.send(:remove_const, :AdminAudit) if Object.const_defined?(:AdminAudit, false)
    Object.const_set(:AdminAudit, @original_admin_audit) if @original_admin_audit
  end

  def audit_calls = @audit_calls
end
