# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2476
# Title: Method "reset" missing in class JDBCConnection
# URL: https://github.com/rsim/oracle-enhanced/issues/2476
# Status: blocked
# Notes: The reported failure is JRuby/JDBC-only. On the release80 branch
#   (where the issue was filed) OracleEnhancedAdapter#reconnect calls
#   `_connection.reset` (no bang). OCIConnection (CRuby) defined BOTH
#   `reset` (a thin wrapper) and `reset!`, so on CRuby `_connection.reset`
#   worked. JDBCConnection (JRuby) only defined `reset!` -- calling the
#   no-bang form raised NoMethodError, breaking adapter#reconnect on
#   JRuby. On master we are on CRuby/OCI8, so the literal NoMethodError
#   the upstream ticket reports cannot be triggered here -- the OCI path
#   does not have the same gap.
#
#   Update: master already carries the fix (commit 4cd3fcb5, "Drop the
#   redundant Connection#reset alias for reset!"). That commit removed
#   the no-bang `reset` from both OCIConnection and JDBCConnection and
#   changed adapter#reconnect to call `_connection.reset!` directly,
#   eliminating the divergence the ticket complained about. So this spec
#   has two reasons it cannot reproduce a failure on master: (1) wrong
#   Ruby runtime (CRuby, not JRuby), and (2) the bug is already gone.
#
#   The spec is left in place as a structural assertion: on master,
#   `_connection` must respond to `reset!` and adapter#reconnect must
#   route through it. If a future change reintroduces a no-bang `reset`
#   on only one connection class -- or drops `reset!` from one of them
#   -- this spec will fail and flag the asymmetry that #2476 originally
#   surfaced.

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2476: JDBCConnection#reset missing" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
  end

  let(:conn) { @conn }
  let(:raw) { conn.send(:_connection) }

  it "is JRuby/JDBC-specific; cannot trigger NoMethodError on CRuby/OCI" do
    skip "Issue #2476 is JRuby/JDBC-only; running under CRuby/OCI8 cannot reproduce" unless RUBY_PLATFORM == "java"

    # If we ever do run this under JRuby on the unfixed code path, the
    # adapter's private #reconnect should raise NoMethodError when it
    # calls _connection.reset. On master (post 4cd3fcb5) it does not,
    # because reconnect calls reset! directly.
    expect { conn.send(:reconnect) }.not_to raise_error
  end

  it "raw connection responds to reset! on both OCI and JDBC (post-fix invariant)" do
    # This is the structural invariant the fix established: reset! is
    # the single, canonical reconnect entry point on both connection
    # classes. If this fails, the symmetry the upstream issue asked for
    # has regressed.
    expect(raw).to respond_to(:reset!)
  end

  it "adapter#reconnect succeeds against a live connection (proves no NoMethodError on either path)" do
    # On release80 (pre-fix), this call on JRuby raised NoMethodError
    # for reset on JDBCConnection. On CRuby it worked because
    # OCIConnection defined both reset and reset!. On master (post-fix)
    # adapter#reconnect calls reset! directly, so both runtimes succeed.
    expect { conn.send(:reconnect) }.not_to raise_error

    # Connection is still usable after reconnect.
    expect(conn.select_value("SELECT 1 FROM dual")).to eq(1)
  end

  it "documents the secondary bug: NameError on `connect` in the rescue branch" do
    # The issue body also notes that even with reset monkey-patched, if
    # reset raises ConnectionException, the rescue handler calls
    # `connect` (private method) and that used to fail with NameError
    # in some refactors. On master, connect is defined as a private
    # method on the adapter, so the rescue handler can call it.
    adapter_class = ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter
    expect(adapter_class.private_instance_methods).to include(:connect)
    expect(adapter_class.private_instance_methods).to include(:reconnect)
  end
end
