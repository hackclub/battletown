# Replaces `object.name` with `impl` for the block and puts back exactly what was there, even when the block raises (Minitest 6 no
# longer ships stub). Available in every test. Returns the calls made, so a test can prove the stub was really reached.
#
#   calls = stub_method(AdminAudit, :record!, ->(**) { raise "audit down" }) { patch ... }
module StubMethod
  def stub_method(object, name, impl)
    original = object.method(name)
    calls = []
    object.define_singleton_method(name) { |*args, **kwargs, &block| calls << [ args, kwargs ]; impl.call(*args, **kwargs, &block) }
    yield
    calls
  ensure
    # Back to exactly the original: drop our singleton override first, then re-define only when the method was a singleton one.
    object.singleton_class.send(:remove_method, name) if object.singleton_class.instance_methods(false).include?(name)
    object.define_singleton_method(name, original) if original.owner == object.singleton_class
  end
end
