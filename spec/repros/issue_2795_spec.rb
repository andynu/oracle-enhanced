# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2795
# Title: Implement supports_update_returning? to auto-reload virtual columns on UPDATE (Rails #48628)
# URL: https://github.com/rsim/oracle-enhanced/issues/2795
# Status: reproduced
# Notes: Confirmed against Oracle XE + ActiveRecord 8.2.0.alpha (which ships the
#   new `supports_update_returning?` / `update_with_result` / `auto_populated_on_update?`
#   machinery from rails/rails#48628). The oracle-enhanced adapter does not override
#   `supports_update_returning?`, so it inherits the abstract default of `false` and
#   Rails takes the legacy `_update_record` path. Concrete symptom: after
#   `record.update!(first_name: "Jane")` the in-memory `record.full_name` still holds
#   the pre-update virtual-column value ("John Doe") even though the row in the
#   database has been recomputed ("Jane Doe"). Once the adapter opts in (issue's
#   "Acceptance" criteria), `_update_record_with_result` will refresh virtual columns
#   in-place via `UPDATE ... RETURNING ... INTO :bind` in a single round trip.

require "spec_helper"

RSpec.describe "Issue #2795: supports_update_returning? for virtual column auto-reload" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection

    skip "Oracle version does not support virtual columns" unless @conn.supports_virtual_columns?

    @conn.create_table :test_issue_2795_employees, force: true do |t|
      t.string :first_name, limit: 20
      t.string :last_name,  limit: 25
      t.virtual :full_name, as: "(first_name || ' ' || last_name)", type: :string
    end

    class ::TestIssue2795Employee < ActiveRecord::Base
      self.table_name = "test_issue_2795_employees"
    end
  end

  after(:all) do
    if defined?(::TestIssue2795Employee)
      Object.send(:remove_const, :TestIssue2795Employee)
    end
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table :test_issue_2795_employees, if_exists: true
    ActiveRecord::Base.clear_cache!
  end

  it "fails to advertise supports_update_returning? (feature not yet implemented)" do
    # This is the heart of the feature request. Currently inherits AbstractAdapter's
    # default of `false`. Once issue #2795 is implemented, the adapter should opt in.
    expect(@conn.supports_update_returning?).to be(true),
      "Adapter should opt into UPDATE RETURNING so Rails auto-reloads virtual " \
      "columns on update. Currently returns #{@conn.supports_update_returning?.inspect}."
  end

  it "leaves the in-memory virtual column stale after update (user-visible symptom)" do
    # Concrete demonstration of why the feature matters. With the legacy `_update_record`
    # path, ActiveRecord does not re-read recomputed virtual columns; the user has to
    # call `record.reload` explicitly.
    #
    # NOTE: We explicitly `.find` after create to establish a clean baseline. INSERT-side
    # virtual column population is a separate concern (`supports_insert_returning?` is
    # already true on this adapter, but virtual columns specifically are not currently
    # returned). Using `find` isolates this spec to the UPDATE path #2795 targets.
    created = ::TestIssue2795Employee.create!(first_name: "John", last_name: "Doe")
    record = ::TestIssue2795Employee.find(created.id)
    expect(record.full_name).to eq("John Doe"),
      "sanity: a freshly-loaded record should see the server-computed virtual column"

    record.update!(first_name: "Jane")

    # Database HAS the recomputed value:
    fresh_full_name = @conn.select_value(
      "SELECT full_name FROM test_issue_2795_employees WHERE id = #{record.id}"
    )
    expect(fresh_full_name).to eq("Jane Doe"),
      "sanity: Oracle should have recomputed the virtual column server-side"

    # But the in-memory model does NOT reflect it. This expectation is written
    # against the *desired* behaviour (auto-refresh). It will fail today and pass
    # once #2795 is implemented.
    expect(record.full_name).to eq("Jane Doe"),
      "Expected `full_name` to auto-refresh after update via UPDATE ... RETURNING, " \
      "but got #{record.full_name.inspect}. User must currently call `record.reload`."
  end

  it "models the virtual column as auto_populated_on_update? (Rails plumbing in place)" do
    # Sanity check that Rails' new column predicate already returns the right thing
    # for our virtual column. The adapter's column type already reports `virtual? => true`,
    # which `Column#auto_populated_on_update?` aliases to. This isolates the missing
    # piece to the adapter-level `supports_update_returning?` opt-in.
    column = @conn.columns(:test_issue_2795_employees).detect { |c| c.name == "full_name" }
    expect(column).not_to be_nil
    expect(column.virtual?).to be(true)
    expect(column.auto_populated_on_update?).to be(true)
  end
end
