# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2313
# Title: emulate_booleans = false no longer being picked up in rails 7.0.4
# URL: https://github.com/rsim/oracle-enhanced/issues/2313
# Status: fixed-upstream / cannot-reproduce-on-master
# Notes: The reporter (toddwf) upgraded from Rails 6.1.4 / adapter 6.1.x to
#   Rails 7.0.4 / adapter 7.0.2 and found that
#     ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.emulate_booleans = false
#   was no longer respected -- NUMBER(1) columns kept reading as TrueClass /
#   FalseClass instead of Integer. The same setting in initializers had no
#   effect either. The only way to make it work was to monkey-patch the
#   adapter directly.
#
#   Reported against:
#     - Rails 7.0.4
#     - activerecord-oracle_enhanced-adapter 7.0.2
#     - Ruby 3.1.3
#     - Oracle Database 11g Enterprise Edition 11.2.0.4.0
#
#   Root cause (per the PR that fixed it, #2301):
#   `OracleEnhancedAdapter.type_map` is a class-level memoized cache
#   (`@type_map ||= ...`). The cache is populated the first time the adapter
#   needs to map a column -- which on Rails 7 happens during boot, before
#   user-level config in application.rb / initializers has had a chance to
#   flip `emulate_booleans = false`. Once cached, flipping the cattr has
#   no effect: the boolean branch in `initialize_type_map`
#     if OracleEnhancedAdapter.emulate_booleans
#       m.register_type %r(^NUMBER\(1\))i, Type::Boolean.new
#     end
#   has already been evaluated with the old value baked in.
#
#   Fix (released in 7.0.3, present on master): expose `clear_type_map!`
#   and call it from `clear_cache!`. After flipping `emulate_booleans`,
#   callers must either re-establish the connection or call
#   `OracleEnhancedAdapter.clear_type_map!` to drop the cached map; the
#   next access rebuilds it observing the current cattr value.
#
#   Findings on current master (e8e1677c):
#
#   1. With `emulate_booleans = true` (default) and the adapter freshly
#      booted, a NUMBER(1) column reads back as TrueClass/FalseClass.
#      This is the historical default behavior; sanity check.
#
#   2. Setting `emulate_booleans = false` and re-establishing the
#      connection -- which flows through `clear_cache!` ->
#      `clear_type_map!` -- causes the next NUMBER(1) read to return
#      Integer, matching the reporter's expectation. The bug does NOT
#      reproduce on master.
#
#   3. Setting `emulate_booleans = false` WITHOUT clearing the cached
#      type_map (and without re-establishing the connection) is still
#      a no-op on the already-cached column types -- which is exactly
#      the failure mode the reporter hit on 7.0.2. This is expected
#      with memoization and is the contract the fix codifies:
#      flip the flag, then clear the cache (or reconnect).

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2313: emulate_booleans = false is respected" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    @conn.drop_table(:issue_2313_widgets, if_exists: true)
    @conn.create_table :issue_2313_widgets, force: true do |t|
      t.string  :name
      t.integer :flag, limit: 1   # NUMBER(1) -- the column type at the heart of the bug
    end
  end

  after(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    @conn.drop_table(:issue_2313_widgets, if_exists: true)
  end

  before(:each) do
    # Capture the current emulate_booleans value so each example can
    # restore the global default cleanly.
    @original_emulate_booleans =
      ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.emulate_booleans
  end

  after(:each) do
    ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.emulate_booleans =
      @original_emulate_booleans
    ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.clear_type_map!
    ActiveRecord::Base.clear_cache!
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    # Drop any model class that examples introduced so the next example
    # picks up a fresh schema reflection.
    Object.send(:remove_const, :Issue2313Widget) if defined?(Issue2313Widget)
  end

  it "reads NUMBER(1) as Boolean when emulate_booleans is true (sanity check)" do
    ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.emulate_booleans = true
    ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.clear_type_map!
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)

    class ::Issue2313Widget < ActiveRecord::Base
      self.table_name = "issue_2313_widgets"
    end

    Issue2313Widget.create!(name: "w1", flag: 1)
    record = Issue2313Widget.find_by(name: "w1")

    expect(record.flag).to eq(true)
    expect([TrueClass, FalseClass]).to include(record.flag.class)
  end

  it "reads NUMBER(1) as Integer when emulate_booleans is false (bug fixed in #2301)" do
    # This is the exact configuration the reporter set in application.rb on
    # Rails 7.0.4. On adapter 7.0.2 it was a no-op because the type_map was
    # cached before this line ran. On master (post-#2301) it works as long
    # as the type_map is invalidated -- which `establish_connection` does
    # via `clear_cache!` -> `clear_type_map!`.
    ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.emulate_booleans = false
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)

    class ::Issue2313Widget < ActiveRecord::Base
      self.table_name = "issue_2313_widgets"
    end

    Issue2313Widget.create!(name: "w2", flag: 1)
    record = Issue2313Widget.find_by(name: "w2")

    expect(record.flag).to be_a(Integer)
    expect(record.flag).to eq(1)
  end

  it "clear_type_map! is the public hook that makes emulate_booleans changes effective" do
    # Demonstrates the contract the fix codifies: after flipping the flag,
    # callers explicitly invalidate the cached type map. This is what
    # `clear_cache!` (and therefore `establish_connection`) does internally.
    ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.emulate_booleans = false
    ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.clear_type_map!

    class ::Issue2313Widget < ActiveRecord::Base
      self.table_name = "issue_2313_widgets"
    end
    Issue2313Widget.reset_column_information

    flag_col = Issue2313Widget.columns_hash["flag"]
    # With emulate_booleans = false, the registered type for NUMBER(1) is
    # OracleEnhanced::Integer rather than ActiveRecord::Type::Boolean.
    expect(flag_col.sql_type).to match(/NUMBER\(1\)/i)
    expect(flag_col.type).not_to eq(:boolean)
  end
end
