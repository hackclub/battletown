require "test_helper"

class FailOpenCacheStoreTest < ActiveSupport::TestCase
  class BrokenStore
    def initialize(error) = @error = error

    %i[read write increment delete delete_matched].each do |name|
      define_method(name) { |*_args, **_options| raise @error }
    end
  end

  setup do
    @io = StringIO.new
    @old_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@io)
  end

  teardown { Rails.logger = @old_logger }

  test "delegates to a healthy store" do
    store = FailOpenCacheStore.new(ActiveSupport::Cache::MemoryStore.new)
    store.write("k", 1, expires_in: 60)
    assert_equal 2, store.increment("k", 1, expires_in: 60)
    assert_equal 2, store.read("k")
    store.delete("k")
    assert_nil store.read("k")
  end

  test "a broken store makes Rack::Attack count 1 (under the limit) instead of raising" do
    error = ActiveRecord::StatementInvalid.new("PG::UndefinedTable: relation solid_cache_entries does not exist rack::attack:1:req/ip:203.0.113.9")
    cache = Rack::Attack::Cache.new(store: FailOpenCacheStore.new(BrokenStore.new(error)))
    assert_equal 1, cache.count("req/ip:203.0.113.9", 60)
    assert_nil cache.read("req/ip:203.0.113.9")
  end

  test "failures are logged by error class only, and at most once a minute" do
    now = 0.0
    store = FailOpenCacheStore.new(BrokenStore.new(ActiveRecord::StatementInvalid.new("SELECT ... 203.0.113.9")), clock: -> { now })
    3.times { store.increment("rack::attack:1:req/ip:203.0.113.9", 1, expires_in: 60) }
    now += 61
    store.increment("rack::attack:1:req/ip:203.0.113.9", 1, expires_in: 60)

    lines = @io.string.lines
    assert_equal 2, lines.size
    assert_match(/ActiveRecord::StatementInvalid/, lines.first)
    assert_no_match(/203\.0\.113\.9/, @io.string)
  end
end
