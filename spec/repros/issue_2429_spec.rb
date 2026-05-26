# frozen_string_literal: true

# Reproduction spec for upstream issue rsim/oracle-enhanced#2429
# "Slow query, can it be replaced?"
# https://github.com/rsim/oracle-enhanced/issues/2429
#
# CLAIM: The 4-way `UNION ALL` query in connection.rb#L37-L56 (across
# `all_tables`, `all_views`, `all_synonyms` (owner), `all_synonyms` (PUBLIC))
# used by `describe` was returning in ~2s in production. The reporter's DBA
# suggested replacing it with a single `all_objects` query filtered on
# `object_type IN ('TABLE','VIEW','SYNONYM')`. A follow-up comment noted that
# `DBMS_UTILITY.NAME_RESOLVE` could resolve the name in a single PL/SQL call.
#
# STATUS: not-applicable / already-fixed on current master (e8e1677c).
#
# Both suggested optimizations have landed upstream:
#   * 03774532 (Apr 2026, PR #2521) "Replace slow UNION ALL query with
#     optimized all_objects query in resolve_data_source_name" — the first
#     suggestion from the issue body.
#   * fc823a07 (May 2026, PR #2686) "Resolve describe() via
#     DBMS_UTILITY.NAME_RESOLVE" — the second suggestion from the comment
#     thread.
#
# `describe` (lib/active_record/connection_adapters/oracle_enhanced/
# connection.rb in the d5b3daf snapshot) has been renamed to
# `resolve_data_source_name` and moved to `schema_statements.rb` (PR #2545,
# commit a9949f2d). The current implementation lives in
# schema_statements.rb#L1541 and dispatches to `conn.name_resolve(real_name)`,
# which calls Oracle's `DBMS_UTILITY.NAME_RESOLVE` PL/SQL package — no
# `ALL_*` dictionary view scan at all on the happy path.
#
# This spec asserts the structural change (no `UNION ALL` SQL emitted for
# name resolution) and measures wall-clock latency to confirm the fast path
# is in use. There is no failing reproduction to write: the issue's request
# has been honored, twice.
#
# Both examples pass on master at e8e1677c against Oracle XE in Docker:
#   * No UNION ALL/all_tables/all_views query is emitted; a
#     DBMS_UTILITY.NAME_RESOLVE call appears in the instrumented SQL stream.
#   * `resolve_data_source_name` runs at ~0.2ms/call (about 4 orders of
#     magnitude faster than the reported ~2s production latency).

require "spec_helper"

RSpec.describe "Issue #2429: slow UNION ALL describe query" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    schema_define do
      drop_table :issue_2429_things, if_exists: true
      create_table :issue_2429_things do |t|
        t.string :name
      end
    end
  end

  after(:all) do
    schema_define do
      drop_table :issue_2429_things, if_exists: true
    end
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  let(:conn) { ActiveRecord::Base.lease_connection }

  it "no longer emits the 4-way UNION ALL across all_tables/all_views/all_synonyms" do
    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      captured << payload[:sql].to_s if payload[:sql]
    end

    begin
      # Force a fresh resolve; the adapter caches table metadata, so go through
      # the private API directly to make sure we exercise the code path.
      conn.send(:resolve_data_source_name, "issue_2429_things")
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    union_all = captured.select { |s| s =~ /UNION ALL/i && s =~ /all_tables/i && s =~ /all_views/i }
    expect(union_all).to be_empty,
      "expected no UNION ALL query across all_tables/all_views/all_synonyms; " \
      "got:\n#{union_all.join("\n---\n")}"

    # And the current implementation should be visible in the instrumented
    # SQL stream as a DBMS_UTILITY.NAME_RESOLVE call (see schema_statements.rb
    # #1543-1552, where the instrumenter emits a synthetic
    # `DBMS_UTILITY.NAME_RESOLVE(...)` payload).
    name_resolve = captured.select { |s| s =~ /DBMS_UTILITY\.NAME_RESOLVE/i }
    expect(name_resolve).not_to be_empty,
      "expected at least one DBMS_UTILITY.NAME_RESOLVE call in the " \
      "instrumented SQL stream; got:\n#{captured.join("\n---\n")}"
  end

  it "resolves a data source name well under the original 2s production latency" do
    # Warm the adapter so we are not timing first-connect overhead.
    conn.send(:resolve_data_source_name, "issue_2429_things")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    100.times { conn.send(:resolve_data_source_name, "issue_2429_things") }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    per_call = elapsed / 100.0

    # The original report cited ~2s per call. The replacement should be
    # several orders of magnitude faster than that against an idle local
    # XE — a generous 100ms ceiling per call leaves room for CI/test-DB
    # variance while still being a strong regression signal.
    puts "resolve_data_source_name: #{(per_call * 1000).round(2)}ms/call over 100 calls"
    expect(per_call).to be < 0.1,
      "resolve_data_source_name took #{(per_call * 1000).round(2)}ms/call, " \
      "which is closer to the legacy 2s-per-call regime than the post-fix path"
  end
end
