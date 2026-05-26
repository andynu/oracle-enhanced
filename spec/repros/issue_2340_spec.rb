# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2340
# Title: db:schema:load fails with error `NoMethodError: undefined method 'to_sym'
#        for {:type=>:string, :limit=>36}:Hash`
# URL: https://github.com/rsim/oracle-enhanced/issues/2340
# Status: no longer reproducible on master (adapter 8.2.0.alpha + Rails 8.2.0.alpha)
# Notes: Filed against oracle-enhanced 6.1.0 / Rails 6.1. When schema dumps emit
#   `create_table "settings", primary_key: "name", id: { type: :string, limit: 191 }`,
#   schema-load was reported to crash with `NoMethodError: undefined method 'to_sym'
#   for {...}:Hash`. Root cause was the adapter calling `.to_sym` on the `id:` value
#   without first unwrapping the Hash form Rails 6.1 began emitting from
#   SchemaDumper. On current master both forms (with and without an explicit
#   `primary_key:` override) execute cleanly against Oracle XE: the upstream
#   `PrimaryKeyDefinition` / `ColumnDefinition` plumbing now extracts `:type` and
#   `:limit` out of the hash before any adapter code sees it, and oracle-enhanced
#   accepts the unpacked symbol/limit pair via its existing `:primary_key` /
#   `:string` column type paths. This spec is kept as a regression guard so a
#   future refactor that re-introduces a `to_sym` on a Hash value would re-trip
#   the original failure mode.

require "spec_helper"

RSpec.describe "Issue #2340: create_table with id: { type: ..., limit: ... } hash form" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
  end

  after(:each) do
    @conn.drop_table :test_issue_2340_settings, if_exists: true
  end

  it "supports primary_key option combined with id: { type: :string, limit: 36 }" do
    # This mimics what `db:schema:load` would execute when replaying a schema
    # dump containing the hash-form `id:` declaration described in the issue.
    expect {
      @conn.create_table :test_issue_2340_settings,
                        primary_key: "name",
                        id: { type: :string, limit: 36 },
                        force: :cascade do |t|
        t.string :value, limit: 4000
      end
    }.not_to raise_error

    columns = @conn.columns(:test_issue_2340_settings)
    name_col = columns.find { |c| c.name == "name" }
    expect(name_col).not_to be_nil
    expect(name_col.sql_type).to match(/VARCHAR2\(36/i)
  end

  it "supports id: { type: :string, limit: 36 } without an explicit primary_key option" do
    expect {
      @conn.create_table :test_issue_2340_settings,
                        id: { type: :string, limit: 36 },
                        force: :cascade do |t|
        t.string :value
      end
    }.not_to raise_error

    columns = @conn.columns(:test_issue_2340_settings)
    id_col = columns.find { |c| c.name == "id" }
    expect(id_col).not_to be_nil
    expect(id_col.sql_type).to match(/VARCHAR2\(36/i)
  end
end
