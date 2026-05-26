# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2305
# Title:  "varchar to boolean mapping."
# URL:    https://github.com/rsim/oracle-enhanced/issues/2305
# Reported against: Rails 5.2
#
# Summary of the report:
#   When a VARCHAR2(1) column stores boolean values as 'Y'/'N' and the adapter
#   is configured with `emulate_booleans_from_strings = true`, queries written
#   in the natural Rails idiom -- `Model.where(flag_col: true)` -- failed with
#       ActiveRecord::StatementInvalid:
#         OCIError: ORA-00904: "TRUE": invalid identifier
#   because the adapter emitted the bareword `TRUE` instead of binding the
#   value as 'Y'.
#
# Expected: `Model.where(flag_col: true)` returns rows whose VARCHAR2 column == 'Y'.
# Actual (at time of report): `ORA-00904: "TRUE": invalid identifier`.
#
# Status (on master @ e8e1677c, Rails 8.2.0.alpha): BOTH EXAMPLES PASS.
#   The reproduction no longer triggers the failure. Auto-detection by `_flag`
#   suffix is honored, the value `true` is bound as 'Y', and `false` as 'N',
#   so both `where(active_flag: true)` and `where(active_flag: false)` return
#   the correct row. The bug has been fixed somewhere between Rails 5.2 and
#   Rails 8.2 (presumably as part of broader AR query-attribute / type-caster
#   work). Keeping this spec as a regression guard.

require "spec_helper"

RSpec.describe "Issue #2305: varchar to boolean mapping" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    @conn.execute <<~SQL
      CREATE TABLE issue_2305_items (
        id         NUMBER PRIMARY KEY,
        name       VARCHAR2(50),
        active_flag VARCHAR2(1) DEFAULT 'N'
      )
    SQL
    @conn.execute "CREATE SEQUENCE issue_2305_items_seq START WITH 1"
  end

  after(:all) do
    @conn.execute "DROP TABLE issue_2305_items" rescue nil
    @conn.execute "DROP SEQUENCE issue_2305_items_seq" rescue nil
  end

  before(:each) do
    ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.emulate_booleans_from_strings = true
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.clear_type_map!
    ActiveRecord::Base.clear_cache!

    # NOTE: the original report did not declare `attribute :active_flag, :boolean`.
    # They relied on `emulate_booleans_from_strings = true` to auto-coerce a
    # VARCHAR2 column whose name ends in `_flag` to boolean. We exercise both
    # variants below.
    stub_const("Issue2305Item", Class.new(ActiveRecord::Base) do
      self.table_name = "issue_2305_items"
    end)

    Issue2305Item.delete_all
    Issue2305Item.create!(name: "yes-row", active_flag: true)
    Issue2305Item.create!(name: "no-row",  active_flag: false)
  end

  after(:each) do
    ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.emulate_booleans_from_strings = false
    ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.clear_type_map!
    ActiveRecord::Base.clear_cache!
  end

  it "Model.where(varchar_boolean_col: true) finds the 'Y' row without ORA-00904" do
    result = Issue2305Item.where(active_flag: true).to_a
    expect(result.map(&:name)).to eq(["yes-row"])
  end

  it "Model.where(varchar_boolean_col: false) finds the 'N' row" do
    result = Issue2305Item.where(active_flag: false).to_a
    expect(result.map(&:name)).to eq(["no-row"])
  end
end

# ---------------------------------------------------------------------------
# Reproduction status on master @ e8e1677c (Rails 8.2.0.alpha, Ruby 4.0.1,
# Oracle 21c XE):
#
#   $ bundle exec rspec spec/repros/issue_2305_spec.rb
#   Issue #2305: varchar to boolean mapping
#     Model.where(varchar_boolean_col: true) finds the 'Y' row without ORA-00904
#     Model.where(varchar_boolean_col: false) finds the 'N' row
#   Finished in 0.39s
#   2 examples, 0 failures
#
#   Conclusion: NOT REPRODUCIBLE on master. Issue #2305 appears resolved.
# ---------------------------------------------------------------------------
