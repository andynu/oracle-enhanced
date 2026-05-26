# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2713
# Title: Verify Rails-style stored generated columns (Oracle 12c+ GENERATED ALWAYS AS ... STORED)
# URL: https://github.com/rsim/oracle-enhanced/issues/2713
# Status: reproduced
# Notes: Rails 8.2's canonical generated-column DSL is the flat keyword form
#   `t.virtual :col, type: :T, as: "...", stored: true`. The oracle-enhanced
#   adapter does NOT include `:stored` in `valid_column_definition_options`
#   (see lib/active_record/connection_adapters/oracle_enhanced/schema_definitions.rb
#   `valid_column_definition_options` -> only `:as`, `:type`, identity bits).
#   schema_creation emits `AS (expr)` with neither `VIRTUAL` nor `STORED` keyword,
#   so Oracle defaults to VIRTUAL regardless of what the user requested. The
#   `stored: true` request is silently dropped: the column is created as VIRTUAL
#   and the schema dumper round-trips it without the `stored:` keyword. This
#   spec asserts the round-trip we *want* (`stored: true` -> Oracle STORED /
#   MATERIALIZED), and is expected to fail until the adapter implements the
#   keyword. The maintainer's investigation in the issue comments documents
#   why a full round-trip is blocked on a public catalog flag for MATERIALIZED;
#   this spec is the failing-test contract for that work.

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2713 — Rails-style stored generated columns" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
  end

  before(:each) do
    skip "Stored generated columns need Oracle 12c+" unless @conn.database_version >= "12"
  end

  after(:each) do
    @conn.drop_table("issue_2713_items") if @conn.table_exists?("issue_2713_items")
  end

  it "creates a STORED generated column when given `stored: true`" do
    # Canonical Rails 8.2 form: `t.virtual :col, type: :T, as: "...", stored: true`.
    # PostgreSQL/MySQL/SQLite3 all accept this; oracle-enhanced should too.
    expect {
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :issue_2713_items, force: true do |t|
            t.integer :price, default: 0
            t.virtual :price_with_tax,
                      type: :decimal,
                      as: "ROUND(price * 1.2, 2)",
                      stored: true
          end
        end
      end
    }.not_to raise_error,
      "expected adapter to accept Rails' standardised `stored: true` keyword on `t.virtual`. " \
      "Currently `valid_column_definition_options` omits `:stored`, so AR raises ArgumentError."

    # The persisted column must be Oracle-STORED (a.k.a. MATERIALIZED on 23ai),
    # not VIRTUAL. USER_TAB_COLS.VIRTUAL_COLUMN='YES' is set ONLY for VIRTUAL
    # columns; MATERIALIZED rows back as 'NO'. So `virtual_column = 'NO'`
    # together with a populated `data_default` referencing other columns is
    # the dictionary signature of a STORED generated column.
    row = @conn.select_one(<<~SQL)
      SELECT virtual_column, data_default
      FROM user_tab_cols
      WHERE table_name = 'ISSUE_2713_ITEMS'
        AND column_name = 'PRICE_WITH_TAX'
    SQL

    expect(row).not_to be_nil, "expected PRICE_WITH_TAX to exist in user_tab_cols"
    expect(row["virtual_column"]).to eq("NO"),
      "expected STORED column to surface as VIRTUAL_COLUMN='NO'; got #{row['virtual_column'].inspect}. " \
      "The adapter emitted `AS (expr)` with no trailing keyword, so Oracle defaulted to VIRTUAL."
    expect(row["data_default"].to_s).to match(/PRICE/i),
      "expected data_default to reference the source column (signature of a generated column)"
  end

  it "round-trips `stored: true` through the schema dumper" do
    # If forward-create works (previous example), the dumper should round-trip.
    # If forward-create doesn't work, this also fails — either way the failure
    # documents the gap.
    begin
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :issue_2713_items, force: true do |t|
            t.integer :price, default: 0
            t.virtual :price_with_tax,
                      type: :decimal,
                      as: "ROUND(price * 1.2, 2)",
                      stored: true
          end
        end
      end
    rescue ArgumentError
      # Adapter rejects `stored:`. The forward-create spec captures that;
      # for this spec we still want to assert the dumper contract, so we
      # fall back to creating the column without `stored:` and document
      # that the round-trip is impossible without forward support.
      ActiveRecord::Schema.define do
        suppress_messages do
          create_table :issue_2713_items, force: true do |t|
            t.integer :price, default: 0
            t.virtual :price_with_tax, type: :decimal, as: "ROUND(price * 1.2, 2)"
          end
        end
      end
    end

    stream = StringIO.new
    old_ignore = ActiveRecord::SchemaDumper.ignore_tables
    ActiveRecord::SchemaDumper.ignore_tables = @conn.data_sources - ["issue_2713_items"]
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, stream)
    ActiveRecord::SchemaDumper.ignore_tables = old_ignore
    dump = stream.string

    expect(dump).to match(/t\.virtual\s+"price_with_tax"/),
      "expected dump to include a `t.virtual` line for price_with_tax"
    expect(dump).to match(/stored:\s*true/),
      "expected dump to emit `stored: true` keyword to round-trip the STORED generated column.\n" \
      "Dump was:\n#{dump}"
  end
end
