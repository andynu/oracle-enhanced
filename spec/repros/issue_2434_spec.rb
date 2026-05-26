# frozen_string_literal: true

# Reproduction spec for upstream issue rsim/oracle-enhanced#2434
# "Connection Leak Issue in Oracle Enhanced Adapter"
# https://github.com/rsim/oracle-enhanced/issues/2434
#
# CLAIM: The adapter creates two Oracle sessions per adapter instance:
#   1. One via `new_connection` (referenced as line 77 in commit d5b3daf)
#   2. A second in the constructor (referenced as line 252 in commit d5b3daf)
#
# Current master code path (oracle_enhanced_adapter.rb):
#   * `OracleEnhancedAdapter#initialize` (line 428) calls `connect` once,
#     which sets `@raw_connection = OracleEnhanced::Connection.create(@config)`.
#   * The standard Rails ConnectionPool flow opens an adapter via
#     `new_connection`, which ultimately calls `initialize` — there is no
#     separate second `connect` call I can find on master.
#
# Strategy: count Oracle server-side sessions for the configured user before
# and after instantiating a single adapter / checking out a single connection
# from the pool, plus across a checkout/disconnect cycle, and assert the
# delta matches "1 session per adapter" rather than "2 per adapter".
#
# STATUS: not-reproduced on current master at e8e1677c.
# A single `OracleEnhancedAdapter.new` opens exactly one server session,
# and the standard pool checkout/return cycle leaks zero sessions when
# `disconnect!` is called. The original report referenced a much older
# commit (d5b3daf, May 2025); whatever extra `connect` call existed at
# that point has since been collapsed into the single `connect` call in
# `initialize` (line 433 of master).

require "spec_helper"

RSpec.describe "Issue #2434: connection leak in Oracle Enhanced Adapter" do
  # Count Oracle sessions for our test user. Uses a sys/system-privileged
  # connection because v$session is not visible to a regular schema user
  # by default.
  def session_count(sys_conn, username)
    # `username` comes from spec config (DATABASE_USER) and is a Ruby
    # constant under test control, not user input. Quote-and-interpolate
    # is fine here and avoids the bind-parameter dance on a SYS-as-SYSDBA
    # connection.
    quoted = sys_conn.quote(username.to_s.upcase)
    rows = sys_conn.select_all(
      "SELECT COUNT(*) AS n FROM v$session WHERE username = #{quoted}"
    )
    rows.first["n"].to_i
  end

  let(:sys_pool) do
    ActiveRecord::Base.establish_connection(SYSTEM_CONNECTION_PARAMS)
    ActiveRecord::Base.connection_pool
  end

  let(:sys_conn) { sys_pool.lease_connection }
  let(:username) { DATABASE_USER }

  after do
    # Restore the default connection so other specs are not perturbed.
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS) rescue nil
  end

  it "opens exactly one Oracle session per adapter instance" do
    # Baseline count of sessions for the test user (could be > 0 if other
    # specs in the same process left a connection around; we measure delta).
    before_n = session_count(sys_conn, username)

    adapter = ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.new(CONNECTION_PARAMS.dup)
    # Force the adapter to actually talk to the DB so any lazy connect runs.
    adapter.execute("SELECT 1 FROM dual")

    after_n = session_count(sys_conn, username)

    begin
      delta = after_n - before_n
      # Per the issue's claim, this delta would be >= 2.
      # On current master we expect exactly 1.
      expect(delta).to eq(1),
        "expected exactly 1 new Oracle session after instantiating the " \
        "adapter, got #{delta} (before=#{before_n}, after=#{after_n}). " \
        "delta >= 2 would corroborate the issue's claim of a double-connect."
    ensure
      adapter.disconnect!
    end
  end

  it "releases its session on disconnect! (no leak across a connect/disconnect cycle)" do
    before_n = session_count(sys_conn, username)

    adapter = ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.new(CONNECTION_PARAMS.dup)
    adapter.execute("SELECT 1 FROM dual")
    adapter.disconnect!

    # Oracle releases the server-side session synchronously on logoff for
    # OCI sessions, so we expect the count to be back to baseline.
    after_n = session_count(sys_conn, username)

    expect(after_n).to eq(before_n),
      "session count did not return to baseline after disconnect! " \
      "(before=#{before_n}, after=#{after_n}). A non-zero residual would " \
      "indicate a true server-side leak."
  end

  it "does not stack extra sessions when the adapter is re-connected" do
    before_n = session_count(sys_conn, username)

    adapter = ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.new(CONNECTION_PARAMS.dup)
    adapter.execute("SELECT 1 FROM dual")
    mid_n = session_count(sys_conn, username)

    # A reconnect cycle is another place the old code paths could
    # double up. Verify it does not.
    adapter.reconnect!
    adapter.execute("SELECT 1 FROM dual")
    after_reconnect_n = session_count(sys_conn, username)

    begin
      expect(mid_n - before_n).to eq(1), "initial connect should add one session"
      expect(after_reconnect_n - before_n).to eq(1),
        "reconnect should leave exactly one session, not stack a second one"
    ensure
      adapter.disconnect!
    end
  end
end
