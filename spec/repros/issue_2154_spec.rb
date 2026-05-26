# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2154
# Title: class com.sun.proxy.$Proxy73 cannot be cast to class oracle.jdbc.OracleConnection
# URL: https://github.com/rsim/oracle-enhanced/issues/2154
# Status: not-reproduced (JRuby/JDBC + TomEE-only; CRuby + OCI8 environment here)
# Reporter: toao (2021-03-17)
#
# One-liner: When the adapter is configured with `jndi:` against a TomEE
#   DataSource that wraps OracleConnection in a java.lang.reflect.Proxy
#   (com.sun.proxy.$ProxyN), CLOB.createTemporary in jdbc_quoting.rb:14
#   blows up with ClassCastException because @raw_connection.raw_connection
#   is the JDBC interface proxy, not the concrete oracle.jdbc.OracleConnection.
#
# Crash site from the issue's stacktrace:
#   oracle.sql.CLOB.createTemporary(oracle/sql/CLOB.java:786)
#   ... lib/.../oracle_enhanced/jdbc_quoting.rb:14 in `_type_cast'
#
# Mechanism:
#   - User configures `accessToUnderlyingConnectionAllowed true` on the
#     TomEE Resource. That setting historically belonged to the Apache
#     Commons DBCP pool, which exposes getInnermostDelegate() /
#     getUnderlyingConnection(). The adapter handles those two cases at
#     lib/active_record/connection_adapters/oracle_enhanced/jdbc_connection.rb:93-99
#     by unwrapping to the inner driver Connection.
#   - Modern TomEE/Tomcat-JDBC pools instead present a java.sql.Wrapper
#     Proxy whose unwrap target is `oracle.jdbc.OracleConnection`, and
#     they do NOT respond to getInnermostDelegate / getUnderlyingConnection.
#     The adapter's two-branch unwrap therefore falls through, leaving
#     @raw_connection set to a com.sun.proxy.$ProxyN. The interface proxy
#     satisfies java.sql.Connection but cannot be cast to OracleConnection,
#     which the Oracle native `CLOB.createTemporary(Connection, ...)`
#     overload requires under the hood.
#
# Why this spec doesn't fully reproduce on CRuby:
#   - The crash is in a JRuby/JDBC code path. On CRuby + OCI8 the
#     `Java::OracleSql::CLOB` constant doesn't exist; jdbc_quoting.rb
#     isn't even loaded. There is no portable way to construct a
#     java.lang.reflect.Proxy implementing oracle.jdbc.OracleConnection
#     from CRuby. The repro is recorded as a contract check on the
#     unwrap path so that:
#       (a) future maintainers can see exactly which two lines decide
#           whether the bug fires, and
#       (b) a regression that removes or moves the unwrap code will
#           fail this spec loudly.
#   - The "fix" the upstream issue is implicitly asking for is to add a
#     third branch that tries `Wrapper.unwrap(OracleConnection)` before
#     falling through, e.g.:
#         elsif @raw_connection.respond_to?(:isWrapperFor) &&
#               @raw_connection.isWrapperFor(Java::oracle.jdbc.OracleConnection.java_class)
#           @pooled_connection = @raw_connection
#           @raw_connection = @raw_connection.unwrap(Java::oracle.jdbc.OracleConnection.java_class)
#         end
#     That branch is NOT present on master as of e8e1677c (2026-05-26).
#
# System reported by issue author:
#   Rails 6.0.3.5 / oracle-enhanced 6.0.6 / JRuby 9.2.16.0 / Oracle 19c

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2154: JDBC Wrapper proxy not unwrapped to OracleConnection" do
  let(:jdbc_connection_src) do
    File.read(
      File.expand_path(
        "../../../lib/active_record/connection_adapters/oracle_enhanced/jdbc_connection.rb",
        __FILE__
      )
    )
  end

  let(:jdbc_quoting_src) do
    File.read(
      File.expand_path(
        "../../../lib/active_record/connection_adapters/oracle_enhanced/jdbc_quoting.rb",
        __FILE__
      )
    )
  end

  context "live reproduction on CRuby" do
    it "is blocked: JDBC connection pool ClassCastException is not reachable from CRuby + OCI8" do
      pending(
        "Requires JRuby + TomEE-style JDBC pool whose getConnection() returns " \
        "a java.lang.reflect.Proxy implementing java.sql.Connection but not " \
        "oracle.jdbc.OracleConnection. The local CRuby + OCI8 + Oracle XE " \
        "environment cannot construct such a proxy. Reproduction belongs in " \
        "a JRuby + TomEE container test bed."
      )
      raise "force-pending: reproduction unavailable on this engine (RUBY_ENGINE=#{RUBY_ENGINE})"
    end
  end

  # Pin the suspect lines via source-level assertions so future regressions
  # in this exact unwrap path are visible without a live JDBC reproduction.
  context "unwrap code path in jdbc_connection.rb (suspect site for #2154)" do
    it "still has the getInnermostDelegate branch (Commons DBCP unwrap)" do
      expect(jdbc_connection_src).to match(/respond_to\?\(:getInnermostDelegate\)/),
        "The DBCP getInnermostDelegate branch is missing — jdbc_connection.rb has " \
        "been refactored; re-evaluate this reproduction."
    end

    it "still has the getUnderlyingConnection branch (jBoss / older DBCP unwrap)" do
      expect(jdbc_connection_src).to match(/respond_to\?\(:getUnderlyingConnection\)/),
        "The getUnderlyingConnection branch is missing — jdbc_connection.rb has " \
        "been refactored; re-evaluate this reproduction."
    end

    it "still lacks a java.sql.Wrapper#unwrap(OracleConnection) branch (the actual #2154 fix)" do
      # This is the negative-pin that documents the bug. If/when upstream
      # adds a Wrapper.unwrap branch, this expectation will flip and the
      # spec author should reverse the polarity (or close the repro).
      has_wrapper_unwrap_branch = jdbc_connection_src.match?(/isWrapperFor|\.unwrap\(/)
      expect(has_wrapper_unwrap_branch).to be(false),
        "jdbc_connection.rb now appears to call isWrapperFor / unwrap — " \
        "issue #2154 may be fixed. Flip this assertion or close the repro."
    end
  end

  context "CLOB/BLOB createTemporary call site in jdbc_quoting.rb (crash site for #2154)" do
    it "still passes @raw_connection.raw_connection straight to CLOB.createTemporary" do
      # This is the line the user's stacktrace points at:
      #   jdbc_quoting.rb:14  CLOB.createTemporary(@raw_connection.raw_connection, ...)
      # The cast failure happens inside the native createTemporary because the
      # arg is a Proxy, not OracleConnection. If this call site is rewritten
      # to unwrap defensively (e.g. raw_oracle_connection helper), the bug is
      # most likely fixed and this assertion should be revisited.
      expect(jdbc_quoting_src).to match(
        /CLOB\.createTemporary\(@raw_connection\.raw_connection,/
      ), "CLOB.createTemporary call site has moved/changed — re-evaluate this reproduction."
    end

    it "still passes @raw_connection.raw_connection straight to BLOB.createTemporary" do
      expect(jdbc_quoting_src).to match(
        /BLOB\.createTemporary\(@raw_connection\.raw_connection,/
      ), "BLOB.createTemporary call site has moved/changed — re-evaluate this reproduction."
    end
  end
end
