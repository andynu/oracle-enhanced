# frozen_string_literal: true

# Reproduction spec for upstream issue rsim/oracle-enhanced#2004
# "Very long requests 'Column definitions' before main sql request."
# https://github.com/rsim/oracle-enhanced/issues/2004
#
# CLAIM: When the adapter loads a model's schema, it emits a
# "Column definitions" SCHEMA query that, on some sites, takes
# 10-20 seconds per call -- and is sometimes emitted twice per model.
# The reporter blamed Oracle views in particular. A later commenter
# (rshell, March 2022) suggested batching all per-schema columns into
# one query and caching them, since the per-table query is heavy.
#
# The "Column definitions" query lives at
# lib/active_record/connection_adapters/oracle_enhanced_adapter.rb#L948-L982
# (`column_definitions`). It is a join of `ALL_TAB_COLS` and
# `ALL_COL_COMMENTS` filtered on `(owner, table_name)`.
#
# STATUS on master (e8e1677c): partially mitigated, not eliminated.
#
# What IS fixed:
#   * `resolve_data_source_name` (the "describe" step that runs before
#     `column_definitions`) was rewritten to call
#     `DBMS_UTILITY.NAME_RESOLVE` instead of the 4-way UNION ALL.
#     See PR #2686 / issue #2429.
#   * The adapter has a per-connection `@columns_cache`
#     (schema_statements.rb#L189-L196) so a single connection only
#     pays the "Column definitions" cost once per table.
#
# What is NOT fixed:
#   * The "Column definitions" SQL itself is unchanged on master:
#     it still joins `all_tab_cols` against `all_col_comments`,
#     which is the expensive shape rshell's comment called out.
#     No batched/single-call "build_columns_cache" landed.
#   * `Model.columns` against a view still emits exactly one
#     "Column definitions" call per uncached table_name (the cache
#     is keyed on the *passed* table_name string, so calling
#     `columns("FOO")` vs `columns("foo")` is two queries -- mild
#     foot-gun consistent with the "sometimes twice" report).
#   * The cache is per-connection, so every fresh connection
#     (forked workers, new pool checkout after pool reset) pays
#     full price again. That matches the reporter's "very slow on
#     `rails server` startup" scenario.
#
# This spec documents the current behavior:
#
#   1. The "Column definitions" SQL is still all_tab_cols + all_col_comments.
#      (regression signal: the SQL shape should be considered when
#      evaluating future PRs that change it.)
#   2. Repeated `columns(table)` on one connection hits cache --
#      exactly one "Column definitions" notification fires for N calls.
#   3. Case-mismatched table names defeat the cache: `columns("foo")`
#      followed by `columns("FOO")` emits two "Column definitions"
#      calls. This is the residual sharp edge from the original
#      report ("sometimes 'Column definitions' happens twice").
#
# Running against Oracle XE in Docker the SQL is fast (~1ms) so we
# can't reproduce the 10-20s wall-clock latency the user saw; that
# came from a busy production instance with many objects in
# `all_tab_cols`. We assert structural facts instead of timing.

require "spec_helper"

RSpec.describe "Issue #2004: slow 'Column definitions' SCHEMA query" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    schema_define do
      drop_table :issue_2004_things, if_exists: true
      create_table :issue_2004_things do |t|
        t.string :name
        t.integer :value
        t.text :description
      end
    end
  end

  after(:all) do
    schema_define do
      drop_table :issue_2004_things, if_exists: true
    end
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  let(:conn) { ActiveRecord::Base.lease_connection }

  def capture_column_definitions
    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |name, started, finished, _id, payload|
      next unless payload[:name] == "SCHEMA"
      sql = payload[:sql].to_s
      next unless sql =~ /all_tab_cols/i && sql =~ /all_col_comments/i
      captured << { sql: sql, duration_ms: ((finished - started) * 1000.0) }
    end
    begin
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    captured
  end

  it "still emits the all_tab_cols + all_col_comments join (no batched-cache fix landed)" do
    conn.send(:clear_table_caches, "issue_2004_things")

    captured = capture_column_definitions do
      conn.columns("issue_2004_things")
    end

    expect(captured.size).to eq(1),
      "expected exactly one 'Column definitions' query, got #{captured.size}"

    sql = captured.first[:sql]
    expect(sql).to match(/all_tab_cols/i)
    expect(sql).to match(/all_col_comments/i),
      "current implementation still joins all_col_comments, which is the " \
      "expensive shape rshell flagged in 2022. If a batched/cache PR has " \
      "landed and changed the shape, update this spec."
  end

  it "caches per-connection: repeated columns(table) hits cache after the first call" do
    conn.send(:clear_table_caches, "issue_2004_things")

    captured = capture_column_definitions do
      5.times { conn.columns("issue_2004_things") }
    end

    expect(captured.size).to eq(1),
      "expected per-connection @columns_cache to suppress repeat queries; " \
      "got #{captured.size} 'Column definitions' calls"
  end

  it "is case-sensitive in the cache key: mixed-case names re-query (sharp edge)" do
    conn.send(:clear_table_caches, "issue_2004_things")
    conn.send(:clear_table_caches, "ISSUE_2004_THINGS")

    captured = capture_column_definitions do
      conn.columns("issue_2004_things")
      conn.columns("ISSUE_2004_THINGS")
    end

    # Document the current behavior. If a future PR normalizes the cache
    # key (e.g. downcases before lookup) this assertion will flip and the
    # spec needs updating -- which is the correct outcome.
    expect(captured.size).to eq(2),
      "expected case-mismatched names to defeat the cache " \
      "(documents the 'sometimes Column definitions happens twice' report); " \
      "got #{captured.size}. If this dropped to 1, the cache was made " \
      "case-insensitive -- update the spec."
  end

  it "reports per-call latency for the 'Column definitions' query on this DB" do
    conn.send(:clear_table_caches, "issue_2004_things")

    # Run a handful of cold calls (clearing cache each time) to get a feel
    # for SQL latency on the test DB. This is informational, not a hard
    # assertion: the reporter saw 10-20s on production with thousands of
    # objects; XE in Docker is empty by comparison.
    samples = []
    10.times do
      conn.send(:clear_table_caches, "issue_2004_things")
      captured = capture_column_definitions do
        conn.columns("issue_2004_things")
      end
      samples << captured.first[:duration_ms] if captured.first
    end

    avg = samples.sum / samples.size.to_f
    max = samples.max
    puts "Column definitions cold-call: avg=#{avg.round(2)}ms max=#{max.round(2)}ms over #{samples.size} samples"

    # Loose sanity check -- if a single call against an empty XE takes
    # >2s, something is very wrong (probably the user's production-class
    # regression). Production users saw 10-20s.
    expect(max).to be < 2_000,
      "cold 'Column definitions' query took #{max.round}ms on a near-empty " \
      "Oracle XE; production users reported 10-20s on busy instances. " \
      "This is the unfixed problem from issue #2004."
  end
end
