# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2355
# Title: DB connection pool is not used when creating new connections
# URL:   https://github.com/rsim/oracle-enhanced/issues/2355
# Status: reproduced
#
# Summary
# -------
# The reporter observed that "@connection is different on every request even
# though pool size is 5" and asked for OCI8 connection-pool support
# (OCI8::ConnectionPool / OCI8 session pooling) inside the adapter.
#
# OracleEnhancedOCIFactory.new_connection (oci_connection.rb) opens a brand
# new physical OCI8 session every time ActiveRecord asks for a connection.
# There is no OCI8::ConnectionPool / session-pool involved -- every AR pool
# checkout that triggers `connect!` results in a fresh `OCI8.new` and a
# fresh row in `v$session`.
#
# This spec demonstrates:
#   1. Each call to OracleEnhancedOCIFactory.new_connection produces a
#      distinct OCI8 instance (distinct object_id) -- no pool reuse.
#   2. Each new connection corresponds to a new Oracle session in
#      v$session, confirmed via a SYS connection.
#
# If OCI8 session pooling were in use, repeated calls would reuse a small
# fixed set of physical sessions instead of creating N new ones for N calls.

require "spec_helper"

RSpec.describe "issue #2355: oracle-enhanced does not use OCI8 connection pooling" do
  before(:all) do
    # SYS connection used to inspect v$session.
    @sys_conn = OCI8.new("sys", DATABASE_SYS_PASSWORD,
                         "//#{DATABASE_HOST}:#{DATABASE_PORT}/#{DATABASE_NAME}",
                         :SYSDBA)
  end

  after(:all) do
    @sys_conn&.logoff
  end

  def session_count_for(username)
    cursor = @sys_conn.parse("SELECT COUNT(*) FROM v$session WHERE username = :1")
    cursor.bind_param(1, username.upcase)
    cursor.exec
    row = cursor.fetch
    cursor.close
    row.first.to_i
  end

  it "creates a fresh OCI8 session for each new_connection call (no pooling)" do
    factory = ActiveRecord::ConnectionAdapters::OracleEnhanced::OracleEnhancedOCIFactory

    n = 5
    connections = Array.new(n) { factory.new_connection(CONNECTION_PARAMS) }

    # If a session pool were in use, repeated calls would hand back the same
    # (or a small set of) underlying OCI8 instance(s). Without pooling each
    # call returns a distinct OCI8 object.
    object_ids = connections.map(&:object_id).uniq
    # Expectation expresses the desired (pooled) behavior. Spec currently
    # fails because every call returns a distinct OCI8 instance.
    expect(object_ids.size).to be < n,
      "expected pool reuse (<#{n} unique OCI8 instances), got #{object_ids.size} -- " \
      "every call to OracleEnhancedOCIFactory.new_connection spawned a fresh OCI8 session"
  ensure
    connections&.each { |c| c.logoff rescue nil }
  end

  it "opens a new physical Oracle session per AR pool connection (v$session grows)" do
    user = CONNECTION_PARAMS[:username]
    baseline = session_count_for(user)

    factory = ActiveRecord::ConnectionAdapters::OracleEnhanced::OracleEnhancedOCIFactory
    n = 5
    raw_conns = Array.new(n) { factory.new_connection(CONNECTION_PARAMS) }

    after = session_count_for(user)
    delta = after - baseline

    # With OCI8 session pooling delta would stay small (bounded by pool size
    # or even zero on reuse). Without pooling, each new_connection adds a
    # row to v$session.
    expect(delta).to be < n,
      "expected fewer than #{n} new v$session rows (pool reuse), saw +#{delta} -- " \
      "OracleEnhancedOCIFactory bypasses OCI8 session pooling"
  ensure
    raw_conns&.each { |c| c.logoff rescue nil }
  end
end
