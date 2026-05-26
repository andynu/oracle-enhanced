# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2468
# Title: Getting primary key with RETURNING INTO doesn't work in Rails 7 and later
# URL: https://github.com/rsim/oracle-enhanced/issues/2468
# Status: not-reproducible-on-master
# Notes: The issue references a Rails 6.1 -> 7.1 upgrade where a model with
#   `self.primary_key = :rid` (and a non-`id` PK populated by a BEFORE INSERT
#   trigger) no longer received the generated id back through RETURNING INTO.
#   The reporter pointed at sql_for_insert in the adapter
#   (sha 820831de of database_statements.rb), where the guard
#       unless pk == false || pk.nil? || pk.is_a?(Array) || pk.is_a?(String)
#   excluded String pks, so the RETURNING ... INTO clause was never appended
#   when AR handed in `pk` as a String (which Rails 7 does after composite-pk
#   normalization).
#
#   On current master that guard has been replaced. `sql_for_insert` now
#   delegates to `columns_for_returning_clause` (database_statements.rb ~L283),
#   which explicitly handles `pk.is_a?(Symbol) || pk.is_a?(String)` and emits
#   the `RETURNING <cols> INTO <binds>` clause for both kinds of pk. This spec
#   exercises the exact scenario from the issue (sequence + BEFORE INSERT
#   trigger via the adapter's `primary_key_trigger: true` schema option,
#   model with `self.primary_key = "rid"`) and the id round-trips correctly,
#   so the upstream bug is no longer reproducible.
#
#   A pending REGRESSION GUARD example is left at the bottom documenting the
#   original broken behaviour, so reintroducing the String-pk exclusion would
#   light up via the existing positive assertions above.

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2468 - RETURNING INTO with String primary_key" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
  end

  before(:each) do
    schema_define do
      create_table :test_issue_2468_things,
                   force: true,
                   primary_key: :rid,
                   primary_key_trigger: true do |t|
        t.string :name
      end
    end
  end

  after(:each) do
    schema_define do
      drop_table :test_issue_2468_things, if_exists: true
    end
    Object.send(:remove_const, :TestIssue2468Thing) if defined?(TestIssue2468Thing)
    ActiveRecord::Base.clear_cache!
  end

  def define_model(pk_value)
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "test_issue_2468_things"
    end
    klass.primary_key = pk_value
    Object.const_set(:TestIssue2468Thing, klass)
    klass
  end

  it "sanity: adapter loads against the live Oracle container" do
    expect(@conn.select_value("SELECT 1 FROM dual").to_i).to eq(1)
  end

  it "sanity: prefetch_primary_key? is false for trigger-backed tables" do
    # If this were true, AR would call next_sequence_value and the bug under
    # discussion (RETURNING INTO) would never be exercised.
    expect(@conn.prefetch_primary_key?(:test_issue_2468_things)).to be false
  end

  it "returns the trigger-generated id when primary_key is set as a Symbol" do
    klass = define_model(:rid)
    record = klass.create!(name: "sym-pk")
    expect(record.rid).not_to be_nil
    expect(record.rid).to be > 0
    expect(record.id).to eq(record.rid)
  end

  it "returns the trigger-generated id when primary_key is set as a String" do
    # The original bug: AR sometimes hands pk to sql_for_insert as a String,
    # not a Symbol. Setting `self.primary_key = 'rid'` (String, not Symbol)
    # exercises that path explicitly. Pre-fix, this code path skipped
    # RETURNING and record.rid was nil after create!.
    klass = define_model("rid")
    record = klass.create!(name: "string-pk")
    expect(record.rid).not_to be_nil,
      "rid should be populated from RETURNING INTO; nil means the adapter " \
      "skipped the RETURNING clause (issue #2468 regression)."
    expect(record.rid).to be > 0
    expect(record.id).to eq(record.rid)
  end

  it "the emitted SQL contains a RETURNING ... INTO clause" do
    klass = define_model("rid")

    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      payload = args.last
      captured << payload[:sql] if payload[:sql] =~ /INSERT INTO .*TEST_ISSUE_2468_THINGS/i
    end

    begin
      klass.create!(name: "returning-check")
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    insert_sql = captured.last
    expect(insert_sql).not_to be_nil
    expect(insert_sql).to match(/RETURNING\s+"RID"\s+INTO\s+:returning_rid/i),
      "Expected adapter to append RETURNING ... INTO; got:\n#{insert_sql}"
  end

  it "the resulting record can be re-fetched by the trigger-generated id" do
    klass = define_model("rid")
    record = klass.create!(name: "roundtrip")
    refetched = klass.find(record.rid)
    expect(refetched.name).to eq("roundtrip")
  end

  xit "REGRESSION GUARD: documents the original Rails-7 sql_for_insert bug" do
    # Pre-fix code (sha 820831de of database_statements.rb) excluded
    # `pk.is_a?(String)` from the RETURNING branch, so this scenario produced
    # a nil id. If this `xit` ever needs to be flipped to `it` because the
    # String-pk handling has been removed again, the positive assertions above
    # will also fail. This pending example exists to document the historical
    # regression contract.
    klass = define_model("rid")
    record = klass.create!(name: "regression")
    expect(record.rid).to be_nil # <-- the old broken behaviour
  end
end
