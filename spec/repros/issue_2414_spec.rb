# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2414
# Title: Unable to establish TCPS connections on Port 2484 with remote Oracle Server
# URL: https://github.com/rsim/oracle-enhanced/issues/2414
# Status: blocked
# Notes: The reporter is using Fluentd's `out_sql` plugin (not Rails) with
#   the oracle_enhanced adapter and a full TNS descriptor that specifies
#   `(PROTOCOL=TCPS)(PORT=2484)`. Their Fluentd config passes BOTH a
#   `host` parameter ("OracleServer") AND a `database` containing the
#   full TNS descriptor. They observe that the client always connects
#   on plain TCP/1521 and never on TCPS/2484.
#
#   Looking at `OracleEnhancedOCIFactory.new_connection` (CRuby/OCI path),
#   the branch selection on `host`/`port`/`sid`/`database` is:
#
#     if    sid        -> build "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)...))"
#                         -- hardcodes TCP, no TCPS option even with sid
#     elsif host == "connection-string" -> use database verbatim
#     elsif host || port -> "//#{host}:#{port}/#{database}" EZCONNECT
#                           -- no PROTOCOL field; OCI defaults to TCP
#     else               -> use database verbatim (TNS alias / descriptor)
#
#   The user's Fluentd config provides host=OracleServer, so the factory
#   takes the EZCONNECT branch and ignores their TCPS descriptor entirely.
#   That is the proximate cause: providing `host` shadows a TNS descriptor
#   passed via `database`. The deeper limitation is that the adapter
#   exposes no `protocol:` knob -- a TCPS connection requires the caller
#   to use the magic `host: "connection-string"` form (and put the full
#   TNS descriptor in `database`), or to omit `host` entirely.
#
#   Why blocked: the local Docker XE listener does not serve TCPS, so we
#   cannot actually open a TLS handshake to port 2484 here. The spec
#   below documents the connection-string construction path (which is
#   the testable surface) by stubbing `OCI8.new` so we can capture the
#   string the factory would have passed. The stubbed example exercises
#   the bug-shaped scenario the reporter hit: host + TNS-descriptor in
#   database silently drops the descriptor. A pending example records
#   the live-connect expectation that this XE can't satisfy.

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2414: TCPS / port 2484 connection" do
  before(:all) do
    skip "OCI factory path is CRuby-only" if defined?(RUBY_ENGINE) && RUBY_ENGINE == "jruby"
  end

  let(:factory) do
    ActiveRecord::ConnectionAdapters::OracleEnhanced::OracleEnhancedOCIFactory
  end

  # Capture the connect-string the factory hands to OCI8.new without
  # actually trying to open a socket. We return a stub OCI8 instance
  # that swallows the autocommit/non_blocking/prefetch_rows setters.
  def capture_connection_string(config)
    captured = nil
    fake_conn = Object.new
    fake_conn.define_singleton_method(:autocommit=) { |_| }
    fake_conn.define_singleton_method(:non_blocking=) { |_| }
    fake_conn.define_singleton_method(:prefetch_rows=) { |_| }

    allow(OCI8).to receive(:new) do |_user, _pass, conn_str, _priv|
      captured = conn_str
      fake_conn
    end

    factory.new_connection(config)
    captured
  end

  it "hardcodes PROTOCOL=TCP in the SID branch (no TCPS option)" do
    config = {
      username: "u", password: "p",
      sid: "ORCL", host: "OracleServer", port: 2484
    }
    conn_str = capture_connection_string(config)
    expect(conn_str).to include("(PROTOCOL=TCP)")
    expect(conn_str).not_to include("TCPS")
    expect(conn_str).to include("(PORT=2484)")
    # Even though the user explicitly asked for port 2484, the descriptor
    # the adapter builds bakes in PROTOCOL=TCP -- so the listener at 2484
    # (a TCPS listener in their case) will reject the plain-TCP handshake.
  end

  it "drops a TNS descriptor passed in `database` when `host` is also set" do
    tns = "(DESCRIPTION=(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCPS)" \
          "(HOST=OracleServer.swqa.tst)(PORT=2484)))" \
          "(CONNECT_DATA=(SERVICE_NAME=orclpdb)))"
    config = {
      username: "u", password: "p",
      host: "OracleServer", port: 2484,
      database: tns
    }
    conn_str = capture_connection_string(config)

    # This is the reporter's exact scenario. The host+port+database path
    # builds an EZCONNECT-style URL and concatenates the (DESCRIPTION...)
    # blob onto it as if it were a service name. OCI sees neither a valid
    # EZCONNECT string nor a clean TNS descriptor; nothing about TCPS or
    # port 2484 survives intact in a way the listener can honour.
    expect(conn_str).to start_with("//OracleServer:2484")
    # The TCPS descriptor is mangled into the tail of the URL rather than
    # being passed through as the full TNS descriptor:
    expect(conn_str).to include("(PROTOCOL=TCPS)")  # text survives,
    expect(conn_str).not_to start_with("(DESCRIPTION") # but not as a TNS frame
  end

  it "preserves a TNS descriptor only when `host` is omitted (workaround)" do
    tns = "(DESCRIPTION=(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCPS)" \
          "(HOST=OracleServer.swqa.tst)(PORT=2484)))" \
          "(CONNECT_DATA=(SERVICE_NAME=orclpdb)))"
    config = {
      username: "u", password: "p",
      database: tns
      # no :host, no :port, no :sid
    }
    conn_str = capture_connection_string(config)
    # Workaround path: with no host/port/sid the factory uses database
    # verbatim, so the caller's TCPS descriptor reaches OCI intact.
    expect(conn_str).to eq(tns)
  end

  it "also preserves a TNS descriptor with the magic host=connection-string sentinel" do
    tns = "(DESCRIPTION=(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCPS)" \
          "(HOST=OracleServer.swqa.tst)(PORT=2484)))" \
          "(CONNECT_DATA=(SERVICE_NAME=orclpdb)))"
    config = {
      username: "u", password: "p",
      host: "connection-string",
      database: tns
    }
    conn_str = capture_connection_string(config)
    expect(conn_str).to eq(tns)
  end

  it "is blocked: local Docker XE listener does not serve TCPS on 2484" do
    pending "Cannot live-test TCPS; the test Oracle XE is configured only " \
            "for plain TCP on 1521. Reproducing the reporter's environment " \
            "would require an Oracle server with a TCPS listener, wallet " \
            "configuration, and certificates -- out of scope for the gem's " \
            "spec suite."
    raise "blocked by environment"
  end
end
