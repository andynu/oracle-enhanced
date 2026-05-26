# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2382
# Title: Can't create a table with default bigint primary key.
# URL: https://github.com/rsim/oracle-enhanced/issues/2382
# Status: not-reproduced (original crash); related-issue-documented
# Notes: The reporter loaded a Rails-dumped schema.rb that contained
#   `create_table "account_users", id: { limit: 19, precision: 19 }, ...`
#   and got:
#     NoMethodError: undefined method `to_sym' for {:limit=>19, :precision=>19}:Hash
#     at activerecord/lib/.../schema_definitions.rb:407 in `column`
#     called from `primary_key` at line 242
#     called from the adapter's `OracleEnhanced::ColumnMethods#primary_key`
#     in `lib/.../oracle_enhanced/schema_definitions.rb:9`.
#
#   This was reported against:
#     - Rails 6.1.7.7
#     - activerecord-oracle_enhanced-adapter 6.1.6
#     - jruby 9.3.13.0 with Oracle 21c XE
#
#   The reporter posted a one-line fix in a follow-up comment: when the
#   `type` positional argument arrives as a Hash, treat it as `options`
#   and reset `type` to `:primary_key`:
#
#     def primary_key(name, type = :primary_key, **options)
#       if type.is_a?(Hash)
#         options = type
#         type = :primary_key
#       end
#       super
#     end
#
#   Findings on current master (e8e1677c, Rails 8.2.0.alpha):
#
#   1. The crash NO LONGER REPRODUCES. Rails' upstream TableDefinition has
#      evidently learned to handle the Hash-typed `id:` argument; passing
#      `id: { limit: 19, precision: 19 }` to `create_table` now succeeds.
#      The reporter's workaround in `OracleEnhanced::ColumnMethods#primary_key`
#      is no longer needed for the NoMethodError -- Rails fixed it upstream.
#
#   2. However, the resulting primary-key column is **NUMBER(38)**, not
#      NUMBER(19). The `limit: 19, precision: 19` options on the Hash are
#      silently dropped for the primary key. The adapter's `NATIVE_DATABASE_TYPES`
#      maps `:primary_key` to a hard-coded "NUMBER(38) NOT NULL PRIMARY KEY"
#      string literal -- there is no path for `limit:` to override it.
#      So a Rails app whose schema.rb dump expects a NUMBER(19) bigint PK
#      ends up with NUMBER(38) on Oracle. That is a separate, latent bug
#      worth its own issue: the schema is loadable but is not round-trip
#      faithful.
#
#   3. The default Rails 8 `create_table :foo` (no `id:` argument, which
#      means `id: :primary_key`) works as expected and produces NUMBER(38).

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2382: bigint primary key via Hash id options" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
  end

  after do
    @conn.drop_table(:issue_2382_foo, if_exists: true)
    @conn.drop_table(:issue_2382_account_users, if_exists: true)
  end

  it "creates a table with the Rails 8 default primary key (sanity check)" do
    # Rails 8 default: `create_table :foo` -> id: :primary_key, which the
    # adapter maps to NUMBER(38) NOT NULL PRIMARY KEY via NATIVE_DATABASE_TYPES.
    # This path does NOT hit the Hash-typed `id:` form.
    expect {
      @conn.create_table :issue_2382_foo, force: true
    }.not_to raise_error
    expect(@conn.table_exists?(:issue_2382_foo)).to be true
    expect(@conn.primary_key(:issue_2382_foo)).to eq("id")
    id_col = @conn.columns(:issue_2382_foo).find { |c| c.name == "id" }
    # Default primary_key on this adapter is NUMBER(38).
    expect(id_col.sql_type).to eq("NUMBER(38)")
  end

  it "no longer crashes on id: { limit: 19, precision: 19 } -- original bug is fixed" do
    # This is the exact construct Rails dumps for a bigint primary key.
    # Under Rails 6.1 + adapter 6.1.6 this raised NoMethodError. On master
    # (Rails 8.2.0.alpha + current adapter) it succeeds.
    expect {
      @conn.create_table :issue_2382_account_users,
                        id: { limit: 19, precision: 19 },
                        force: true do |t|
        t.integer "account_id", limit: 19, precision: 19, null: false
      end
    }.not_to raise_error

    expect(@conn.table_exists?(:issue_2382_account_users)).to be true
    expect(@conn.primary_key(:issue_2382_account_users)).to eq("id")
  end

  it "DOES NOT honor :limit/:precision on the primary key (latent round-trip bug)" do
    @conn.create_table :issue_2382_account_users,
                      id: { limit: 19, precision: 19 },
                      force: true do |t|
      t.integer "account_id", limit: 19, precision: 19, null: false
    end

    id_col = @conn.columns(:issue_2382_account_users).find { |c| c.name == "id" }
    account_id_col = @conn.columns(:issue_2382_account_users).find { |c| c.name == "account_id" }

    # The non-PK column DOES honor the Hash: account_id is NUMBER(19).
    expect(account_id_col.sql_type).to eq("NUMBER(19)")

    # But the PK silently falls back to the adapter's default NUMBER(38)
    # regardless of the limit:/precision: in the Hash. This is the latent
    # bug not addressed by the upstream Rails fix:
    expect(id_col.sql_type).to eq("NUMBER(38)")
    # If/when the adapter starts honoring the Hash options for the PK,
    # this expectation will flip to "NUMBER(19)" -- which is what the
    # reporter's schema.rb intended in the first place.
  end
end
