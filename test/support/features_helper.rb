# Flag helpers for tests. Flipper runs on its in-memory adapter in tests and is reset before every test (flipper/test_help),
# so every flag starts off and nothing leaks between tests or parallel workers (each worker is its own process).
# Included into every test case from test_helper.rb.
#
#   with_feature(:team) { ... }      # the flag is on inside the block, as it was before after it
#   without_feature(:team) { ... }   # the flag is off inside the block
#
# Every gated feature's tests cover both states.
module FeaturesHelper
  def with_feature(name, &block) = with_feature_state(name, true, &block)

  def without_feature(name, &block) = with_feature_state(name, false, &block)

  private

  def with_feature_state(name, state)
    key = Features.validate!(name)
    was = Flipper.enabled?(key)
    state ? Flipper.enable(key) : Flipper.disable(key)
    yield
  ensure
    was ? Flipper.enable(key) : Flipper.disable(key) if key
  end
end
