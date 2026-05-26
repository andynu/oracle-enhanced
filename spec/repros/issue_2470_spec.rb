# frozen_string_literal: true

# Reproduction for upstream issue rsim/oracle-enhanced#2470
# https://github.com/rsim/oracle-enhanced/issues/2470
#
# Title: Method `select_statement?` missing in OracleEnhanced::JDBCConnection::Cursor
#         for branch release80
#
# Reporter: rammpeter (2025-07-14)
#
# Summary: ActiveRecord::ConnectionAdapters::OracleEnhanced::DatabaseStatements#raw_execute
# calls `cursor.select_statement?` (database_statements.rb:373). On JRuby this raised
# NoMethodError because the JDBCConnection::Cursor class did not implement that method —
# only OCIConnection::Cursor did. Any JRuby query (e.g. `Dual.select "SELECT SYSDATE FROM DUAL"`)
# blew up with:
#
#   NoMethodError: undefined method 'select_statement?' for an instance of
#     ActiveRecord::ConnectionAdapters::OracleEnhanced::JDBCConnection::Cursor
#
# Status on master (2026-05-26):
#   - lib/active_record/connection_adapters/oracle_enhanced/oci_connection.rb:177
#     defines `select_statement?` (returns `@raw_cursor.type == :select_stmt`)
#   - lib/active_record/connection_adapters/oracle_enhanced/jdbc_connection.rb:425
#     defines `select_statement?` (returns `!@raw_result_set.nil?`)
#
# Both Cursor classes now implement the method, so the upstream bug is FIXED on master.
# These specs encode the contract so a regression (e.g. dropping the JDBC implementation
# again on a release branch) would fail loudly.
#
# Spec execution:
#   - These specs do NOT require a live Oracle database. They load the constants and
#     assert method presence via reflection. That keeps the reproduction runnable on
#     both CRuby (where JDBCConnection lives behind `if defined?(JRUBY_VERSION)` guards)
#     and JRuby.

require "rubygems"
require "bundler"
Bundler.setup(:default, :development)

$LOAD_PATH.unshift(File.expand_path("../../../lib", __FILE__))

require "rspec"
require "active_record"
require "active_record/connection_adapters/oracle_enhanced_adapter"

# Force load both connection modules so the constants exist regardless of platform.
# On CRuby the OCI path is loaded; the JDBC file is normally only loaded on JRuby
# but the source itself is platform-agnostic at parse time, so we can require it
# directly to inspect the Cursor class. We only require jdbc_connection.rb if it
# can be loaded — on CRuby the `java` require at the top will fail, in which case
# we fall back to a source-level grep assertion.
require "active_record/connection_adapters/oracle_enhanced/oci_connection" if defined?(OCI8) || RUBY_ENGINE == "ruby"

jdbc_loaded = false
begin
  require "active_record/connection_adapters/oracle_enhanced/jdbc_connection"
  jdbc_loaded = true
rescue LoadError, NameError
  jdbc_loaded = false
end

RSpec.describe "Issue #2470: select_statement? on Cursor classes" do
  let(:oci_cursor_const) do
    ActiveRecord::ConnectionAdapters::OracleEnhanced::OCIConnection::Cursor
  end

  let(:jdbc_cursor_const) do
    ActiveRecord::ConnectionAdapters::OracleEnhanced::JDBCConnection::Cursor
  end

  context "OCIConnection::Cursor (the path that always worked)" do
    it "defines #select_statement?" do
      skip "OCI path unavailable on this engine" unless defined?(OCI8) || RUBY_ENGINE == "ruby"
      expect(oci_cursor_const.instance_methods(false)).to include(:select_statement?)
    end
  end

  context "JDBCConnection::Cursor (the regression site from issue #2470)" do
    it "defines #select_statement? at the class level" do
      if jdbc_loaded
        expect(jdbc_cursor_const.instance_methods(false)).to include(:select_statement?)
      else
        # On CRuby we cannot load jdbc_connection.rb (java require fails). Fall back
        # to a source-level check so this spec still runs and still catches the
        # regression described in the upstream issue.
        src = File.read(
          File.expand_path(
            "../../../lib/active_record/connection_adapters/oracle_enhanced/jdbc_connection.rb",
            __FILE__
          )
        )
        expect(src).to match(/def\s+select_statement\?/),
          "JDBCConnection::Cursor#select_statement? is missing — issue #2470 regression"
      end
    end
  end

  context "DatabaseStatements caller site" do
    # The bug report points at database_statements.rb:57 in the reporter's tree,
    # which on master lives at the equivalent of line ~373. Make sure the call
    # site that requires `select_statement?` still exists, so this reproduction
    # doesn't silently rot if the upstream code path moves or changes.
    it "still calls cursor.select_statement? in raw_execute" do
      src = File.read(
        File.expand_path(
          "../../../lib/active_record/connection_adapters/oracle_enhanced/database_statements.rb",
          __FILE__
        )
      )
      expect(src).to include("cursor.select_statement?"),
        "raw_execute no longer calls cursor.select_statement?; re-evaluate this reproduction"
    end
  end
end
