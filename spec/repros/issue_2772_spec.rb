# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2772
# Title: Arel::Nodes::NamedFunction is unconditionally non-retryable, blocking AR retry for several oracle-enhanced predicates
# URL: https://github.com/rsim/oracle-enhanced/issues/2772
# Status: reproduced
# Notes: Confirmed against Oracle XE 21c via Docker + Rails main (8.2.0.alpha).
#   `Arel::Nodes::NamedFunction` unconditionally flips `collector.retryable`
#   to false in AR's `to_sql.rb`, so any oracle-enhanced SELECT rewritten
#   to inject `DBMS_LOB.COMPARE` (CLOB equality) or `UPPER` (case-insensitive
#   LIKE) is marked non-retryable. The spec compiles three Arel managers
#   through `to_sql_and_binds` and asserts the resulting `allow_retry`:
#   plain SELECT returns true (baseline), both rewrites return false. A
#   fourth example pins the upstream Arel visitor behavior so a Rails-side
#   fix (e.g. a `retryable:` kwarg on NamedFunction) will fail it loudly.
#   The fix lives upstream in Rails; this adapter can opt-in known-safe
#   function names once that lands.

require "spec_helper"

# Reproduces the upstream issue that any `Arel::Nodes::NamedFunction`
# emitted during query compilation unconditionally flips
# `collector.retryable = false`, which then propagates out of
# `to_sql_and_binds` as `allow_retry = false`. Two oracle-enhanced
# rewrites in `lib/arel/visitors/oracle_common.rb` inject `NamedFunction`
# nodes into otherwise idempotent SELECTs:
#
#   * CLOB equality   -> `DBMS_LOB.COMPARE(col, ?) = 0`
#   * case-insensitive LIKE -> `UPPER(col) LIKE UPPER(?)`
#
# Both rewrites are read-only and safe to retry on a connection blip,
# but AR's 7.1+ retry path (rails/rails@eabcff22) bails out because
# of the NamedFunction visitor.
RSpec.describe "Issue #2772 - NamedFunction unconditionally non-retryable" do
  TABLE = "issue_2772_docs"

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    @conn.drop_table TABLE, if_exists: true
    @conn.create_table TABLE do |t|
      t.string :title
      t.text   :body # maps to Oracle CLOB
    end
    # Warm the schema cache directly on the leased connection so the
    # Arel visitor's `schema_cache.columns_hash` lookup (which is what
    # triggers the CLOB-equality rewrite) sees the table.
    @conn.schema_cache.columns_hash(TABLE)
  end

  after(:all) do
    @conn.drop_table TABLE, if_exists: true
  end

  let(:connection) { @conn }
  let(:table) { Arel::Table.new(TABLE) }

  # Helper: compile an Arel manager through the adapter's full
  # `to_sql_and_binds` pipeline so we see the same `allow_retry` value that
  # `ActiveRecord::Base.with_raw_connection(allow_retry: ...)` would see.
  def compile_retryable(manager)
    _sql, _binds, _preparable, allow_retry =
      connection.send(:to_sql_and_binds, manager, [], nil, false)
    allow_retry
  end

  describe "AR retry baseline" do
    it "a plain SELECT with no NamedFunction is retryable (sanity check)" do
      manager = table.project(table[:id]).where(table[:title].eq("hello"))
      retryable = compile_retryable(manager)
      expect(retryable).to eq(true), <<~MSG
        Sanity check failed: a plain `SELECT id FROM #{TABLE} WHERE title = ?`
        should be marked retryable by AR. If this fails, AR's retry plumbing
        isn't behaving as expected and the rest of the repro is meaningless.
      MSG
    end
  end

  describe "DBMS_LOB.COMPARE injection via CLOB equality (#2772)" do
    # `oracle_common.rb#visit_Arel_Nodes_Equality` rewrites
    # `col = value` into `DBMS_LOB.COMPARE(col, ?) = 0` when `col` is a
    # text/binary column. The rewrite uses `Arel::Nodes::NamedFunction`,
    # whose AR visitor unconditionally sets `collector.retryable = false`.
    it "is marked non-retryable even though the SQL is a plain SELECT" do
      manager = table.project(table[:id]).where(table[:body].eq("some clob text"))
      sql = manager.to_sql

      # Confirm the rewrite actually happened, otherwise this test is asserting
      # nothing meaningful.
      expect(sql).to include("DBMS_LOB.COMPARE"),
        "Expected oracle_common to inject DBMS_LOB.COMPARE; got: #{sql}"

      retryable = compile_retryable(manager)
      expect(retryable).to eq(false),
        "Reproduction failed: CLOB equality already retryable, issue may be fixed"
    end
  end

  describe "UPPER() injection via case-insensitive Matches (#2772)" do
    # `oracle_common.rb#visit_Arel_Nodes_Matches` rewrites case-insensitive
    # LIKE into `UPPER(left) LIKE UPPER(right)` via two NamedFunction nodes.
    it "is marked non-retryable even though the SQL is a plain SELECT" do
      ci_match = Arel::Nodes::Matches.new(
        table[:title],
        Arel::Nodes.build_quoted("hello%"),
        nil,
        false
      )
      manager = table.project(table[:id]).where(ci_match)
      sql = manager.to_sql

      expect(sql).to match(/UPPER\(.+\) LIKE UPPER\(/i),
        "Expected oracle_common to inject UPPER(...) LIKE UPPER(...); got: #{sql}"

      retryable = compile_retryable(manager)
      expect(retryable).to eq(false),
        "Reproduction failed: case-insensitive LIKE already retryable, issue may be fixed"
    end
  end

  describe "Upstream Arel visitor behavior (root cause)" do
    # This isn't oracle-enhanced specific — it documents the upstream
    # behavior the issue is asking to change. If/when Rails adds a
    # `retryable:` kwarg to NamedFunction and flips this, this test will
    # need updating along with `oracle_common.rb` to opt-in known-safe
    # functions like `DBMS_LOB.COMPARE`, `UPPER`, `LOWER`, `CONTAINS`,
    # `SCORE`, etc.
    it "any NamedFunction in a SELECT forces retryable=false" do
      func = Arel::Nodes::NamedFunction.new("UPPER", [table[:title]])
      manager = table.project(table[:id]).where(func.eq("HELLO"))

      retryable = compile_retryable(manager)
      expect(retryable).to eq(false),
        "Upstream behavior changed: NamedFunction no longer forces non-retryable"
    end
  end
end
