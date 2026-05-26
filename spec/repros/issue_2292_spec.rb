# frozen_string_literal: true

# Repro for rsim/oracle-enhanced#2292 — "prefetch_primary_key? performance issues"
# URL: https://github.com/rsim/oracle-enhanced/issues/2292
#
# Reporter: prefetch_primary_key? called pk_and_sequence_for/describe on
# every save, hitting slow ALL_TRIGGERS / ALL_CONSTRAINTS queries each time
# and degrading insert performance.
#
# Current adapter state (master @ e8e1677c): caching is already in place via
# @prefetch_primary_key_cache (oracle_enhanced_adapter.rb:813-817). The fix
# is present. This repro pins that behaviour so a regression that re-queries
# the dictionary on every call would surface.
#
# Strategy: subscribe to "sql.active_record" notifications and count the
# catalog (SCHEMA) queries emitted by prefetch_primary_key? across N calls.
# - First call: should issue dictionary lookups (identity_primary_key?,
#   trigger_backed_primary_key?, primary_keys).
# - Subsequent calls: cache hit, zero SQL.
#
# RUN RESULT (master @ e8e1677c, Oracle XE 21c via Docker, AR 8.2.0.alpha):
#   3 examples, 0 failures, ~0.42s.
#   - First prefetch_primary_key? call emits SCHEMA queries against the
#     data dictionary (identity/trigger probes).
#   - Calls 2..N hit @prefetch_primary_key_cache and emit zero SCHEMA SQL.
#   - Return value is stable (true) for a plain sequence-backed PK.
# The performance hazard reported in #2292 is no longer reproducible on
# master; this spec exists to lock the cached fast-path in place.

require "spec_helper"

RSpec.describe "Issue #2292: prefetch_primary_key? performance" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
  end

  before(:each) do
    schema_define do
      drop_table :test_pkpf, if_exists: true
      create_table :test_pkpf do |t|
        t.string :name
      end
    end
    @conn.schema_cache.clear!
    # Force cache miss on first call below.
    @conn.instance_variable_get(:@prefetch_primary_key_cache).clear
  end

  after(:each) do
    ActiveRecord::Migration.suppress_messages do
      schema_define do
        drop_table :test_pkpf, if_exists: true
      end
    end
    @conn.schema_cache.clear!
  end

  # Count SCHEMA-tagged sql.active_record events emitted during the block.
  def count_schema_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      count += 1 if event.payload[:name] == "SCHEMA"
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "issues catalog SQL on the first prefetch_primary_key? call" do
    first_call_count = count_schema_queries { @conn.prefetch_primary_key?(:test_pkpf) }
    expect(first_call_count).to be > 0,
      "Expected first prefetch_primary_key? call to issue at least one " \
      "SCHEMA query against the data dictionary, got #{first_call_count}"
  end

  it "issues zero catalog SQL on cached prefetch_primary_key? calls" do
    # Prime the cache.
    @conn.prefetch_primary_key?(:test_pkpf)

    # Subsequent calls must hit the @prefetch_primary_key_cache.
    repeated_count = count_schema_queries do
      10.times { @conn.prefetch_primary_key?(:test_pkpf) }
    end

    expect(repeated_count).to eq(0),
      "Regression: prefetch_primary_key? issued #{repeated_count} SCHEMA " \
      "queries across 10 cached calls. Issue #2292 documents this exact " \
      "behaviour as a performance hazard during inserts."
  end

  it "returns a stable result across repeated calls" do
    results = 5.times.map { @conn.prefetch_primary_key?(:test_pkpf) }
    expect(results.uniq.size).to eq(1)
    expect(results.first).to be true # plain sequence-backed PK
  end
end
