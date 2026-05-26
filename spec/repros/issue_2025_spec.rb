# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2025
#
# Title:  Add basic support for check constraints to database migrations
# URL:    https://github.com/rsim/oracle-enhanced/issues/2025
# Status: not-applicable — already implemented upstream
#
# The issue requests `add_check_constraint`, `remove_check_constraint`, and
# `check_constraints` (the Rails 6.1+ migration API) for the Oracle adapter.
# As of current master, the adapter implements the full API:
#   - `supports_check_constraints?` returns true
#   - `add_check_constraint(table, expression, name:, ...)` issues
#       ALTER TABLE ... ADD CONSTRAINT ... CHECK (...)
#   - `remove_check_constraint(table, name:, ...)` issues
#       ALTER TABLE ... DROP CONSTRAINT ...
#   - `check_constraints(table)` introspects via `all_constraints` and returns
#     `CheckConstraintDefinition` instances (filtering implicit NOT NULLs via
#     `generated = 'USER NAME'`).
#   - `t.check_constraint` inline in `create_table` is also supported, plus
#     `if_not_exists:` / `if_exists:` options and `validate_check_constraint`.
#
# This spec exercises the round trip and asserts the APIs work end-to-end.
# If any of these assertions fail on master, the issue resurrects and the
# header should be flipped from `not-applicable` to a failing repro.

require "spec_helper"

RSpec.describe "Issue #2025 — check constraint migration support" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    @conn.create_table :issue_2025_products, force: true do |t|
      t.string  :name
      t.integer :price
      t.integer :quantity
    end
  end

  after(:all) do
    @conn.drop_table :issue_2025_products, if_exists: true
  end

  after(:each) do
    # Clean up any constraints created by this example so each test starts
    # from a known baseline. `if_exists: true` makes this a no-op when the
    # constraint was never created (e.g. the example failed before adding it).
    @conn.check_constraints(:issue_2025_products).each do |cc|
      @conn.remove_check_constraint :issue_2025_products, name: cc.name, if_exists: true
    end
  end

  it "advertises check-constraint support" do
    expect(@conn.supports_check_constraints?).to be true
  end

  it "adds and introspects a named check constraint" do
    @conn.add_check_constraint :issue_2025_products, "price > 0", name: "issue_2025_price_chk"

    ccs = @conn.check_constraints(:issue_2025_products)
    chk = ccs.detect { |c| c.name == "issue_2025_price_chk" }

    expect(chk).not_to be_nil
    expect(chk.expression).to match(/price\s*>\s*0/i)
  end

  it "removes a check constraint by name" do
    @conn.add_check_constraint :issue_2025_products, "quantity >= 0", name: "issue_2025_qty_chk"
    expect(@conn.check_constraints(:issue_2025_products).map(&:name)).to include("issue_2025_qty_chk")

    @conn.remove_check_constraint :issue_2025_products, name: "issue_2025_qty_chk"
    expect(@conn.check_constraints(:issue_2025_products).map(&:name)).not_to include("issue_2025_qty_chk")
  end

  it "enforces the constraint at the database level" do
    @conn.add_check_constraint :issue_2025_products, "price > 0", name: "issue_2025_enforce_chk"

    expect {
      @conn.execute("INSERT INTO issue_2025_products (id, name, price) VALUES (1, 'bad', -5)")
    }.to raise_error(ActiveRecord::StatementInvalid, /ORA-02290/)
  end
end
