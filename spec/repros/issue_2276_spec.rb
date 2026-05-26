# frozen_string_literal: true

# Reproduction spec for upstream issue rsim/oracle-enhanced#2276
# "Strange error: OCIError: ORA-01008: not all variables bound"
# https://github.com/rsim/oracle-enhanced/issues/2276
#
# REPORTER CLAIM (against rails 7.0.2.3, adapter 7.0.2, ruby-oci8 2.2.11,
# Oracle 10.2):
#   On Rails-app boot, the *first* AR query that runs is built by
#   constructing two Arel relations, calling `.to_sql` on each, and
#   stuffing them into `.from("(#{left.to_sql} UNION ALL #{right.to_sql})")`
#   on a third relation. That third relation explodes with
#   `OCIError: ORA-01008: not all variables bound`.
#
#   The SQL printed in the error message is NOT the user's UNION ALL --
#   it's the adapter's internal column-metadata query
#   (`SELECT cols.column_name ... FROM all_tab_cols cols, all_col_comments
#   comments WHERE cols.owner = :owner AND cols.table_name = :table_name
#   ...`), the one in
#   `lib/active_record/connection_adapters/oracle_enhanced_adapter.rb`
#   around `columns_without_cache` (~line 960 on current master).
#
#   So the bug is: the very first call to `to_sql` on an Arel relation
#   triggers a schema introspection round-trip whose two bind vars
#   (`:owner`, `:table_name`) are somehow not bound when the cursor is
#   executed -- ORA-01008. Reporter notes that pausing in the debugger
#   between `.query` and `.to_sql` makes the failure go away; subsequent
#   identical calls also succeed, so it's a first-call-only state leak.
#
# WHAT THIS SPEC TRIES TO REPRODUCE:
#   The minimal load-bearing fragment of the reporter's setup that is
#   reachable from this gem's spec suite:
#     1. Establish a fresh connection (mirroring the "first query after
#        app start" precondition).
#     2. Build two Arel/AR relations on a freshly-defined model.
#     3. Call `.to_sql` on each (which forces column introspection on a
#        cold cache), then build the UNION ALL wrapper and execute it.
#   If the bug as described in 2026 still exists on master, the very
#   first `.to_sql` (cold-cache) should ORA-01008.
#
# STATUS: not-reproduced. On current master (e8e1677c) against Oracle XE
# in Docker, the cold-cache `.to_sql` -> column introspection path runs
# cleanly. Six years and many Rails/adapter releases on from the report
# (the user was on adapter 7.0.2; we're at master ~9.x), the regression
# they hit appears to be gone. We don't have the reporter's Oracle 10.2
# server, their `composite_primary_keys` configuration, their
# `ArelHelpers::QueryBuilder` wrappers, or their shard-switching
# `around_action`, so a faithful reproduction is out of reach -- but the
# core "first to_sql ORA-01008s on a cold column cache" claim does not
# manifest on current master.
#
# The example below is structured as a failing reproduction (it would
# raise OCIError if the bug were live); it currently passes by asserting
# no exception. If a future regression brings the bug back, swap the
# expectation to `raise_error(/ORA-01008/)` to convert this into a
# red-state TDD spec.

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2276: ORA-01008 on first UNION ALL query" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    schema_define do
      drop_table :issue_2276_components, if_exists: true
      create_table :issue_2276_components do |t|
        t.string  :nhut
        t.string  :cmat
        t.integer :neturef
        t.integer :nveretu
        t.datetime :start_at
        t.boolean :transferred
      end
    end

  end

  after(:all) do
    schema_define do
      drop_table :issue_2276_components, if_exists: true
    end
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  # Build the model fresh per-example so column metadata is cold on each
  # run. The reporter's bug only fires on first-after-boot.
  let(:model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "issue_2276_components"
    end
  end

  def force_cold_column_cache
    # Mirror the "app just booted, no caches warm" state. Clear connection
    # so the next call re-introspects columns through the bound query in
    # oracle_enhanced_adapter.rb around L960.
    ActiveRecord::Base.connection_handler.clear_all_connections!
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
  end

  it "does not raise ORA-01008 on the first UNION ALL .from(...) query of a session" do
    force_cold_column_cache

    # Two leaf relations, just like the reporter's cdp_components1/2.
    left  = model.where(neturef: 1).where("start_at >= ?", 10.years.ago)
    right = model.where(nveretu: 2).where("start_at >= ?", 10.years.ago)

    # This is the exact shape from the issue body:
    #   ::Model.all.select(Arel.star)
    #          .from("(#{left.to_sql} UNION ALL #{right.to_sql})")
    #          .order(...)
    expect {
      sql = "(#{left.to_sql} UNION ALL #{right.to_sql})"
      result = model.select(Arel.star).from(sql).order("nhut, cmat").to_a
      expect(result).to eq([])
    }.not_to raise_error
  end

  it "documents the suspected bind-leak surface: first cold .to_sql call" do
    force_cold_column_cache

    # The reporter's stack trace points at the column-metadata query in
    # oracle_enhanced_adapter.rb (`SELECT ... FROM all_tab_cols cols,
    # all_col_comments comments WHERE cols.owner = :owner AND
    # cols.table_name = :table_name`). That query is bound -- the two
    # named binds in the SQL match the two `bind_string` args passed
    # alongside. ORA-01008 means OCI thinks at least one of the named
    # placeholders never received a value. We exercise the same code
    # path here by forcing a cold-cache to_sql, which is what triggers
    # the introspection.
    expect { model.where(neturef: 42).to_sql }.not_to raise_error
  end
end
