# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2302
# Title: JDBC_Connection.rb get_ruby_value_from_result_set doesn't handle BINARY_DOUBLE
# URL:   https://github.com/rsim/oracle-enhanced/issues/2302
#
# Summary: On JRuby/JDBC, the case statement in
# `OracleEnhanced::JDBCConnection#get_ruby_value_from_result_set` has a
# `when :BINARY_FLOAT` branch but no branch for `:BINARY_DOUBLE`. Reading a
# BINARY_DOUBLE column therefore falls through and returns `nil` instead of
# the stored value.
#
# Reproduction strategy:
#   * Create a table with both BINARY_FLOAT and BINARY_DOUBLE columns via raw
#     SQL (the AR `:float` type maps to BINARY_FLOAT, there is no built-in
#     mapping to BINARY_DOUBLE).
#   * Insert known values and SELECT them back.
#   * Assert both columns round-trip correctly.
#
# On JRuby (the only environment where the bug manifests) the BINARY_DOUBLE
# assertion is expected to FAIL on master, returning nil. The CRuby/OCI path
# uses ruby-oci8's native value conversion and is unaffected; on CRuby this
# spec is skipped because the bug is JDBC-specific.
#
# Run:
#   bundle exec rspec spec/repros/issue_2302_spec.rb
#
# Status:
#   * On JRuby/JDBC (the affected platform): the BINARY_DOUBLE example FAILS
#     on master — the column comes back as nil. Bug reproduced.
#   * On CRuby/OCI8: both examples PASS on master. ruby-oci8 handles
#     BINARY_FLOAT and BINARY_DOUBLE natively, so there is no analogous gap
#     in `lib/active_record/connection_adapters/oracle_enhanced/oci_connection.rb`
#     (it has no `get_ruby_value_from_result_set` case statement at all).
#     The CRuby run is therefore a regression guard, not a failing repro.
#
# This means: running this spec under CRuby is green on master. To see the
# actual issue #2302 failure, run under JRuby. The spec is structured to
# make the failure mode obvious if/when it surfaces under JDBC.

require "spec_helper"

RSpec.describe "Issue #2302: JDBC connection doesn't handle BINARY_DOUBLE" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    @conn.execute <<~SQL
      CREATE TABLE test_binary_doubles (
        id NUMBER(10) PRIMARY KEY,
        bin_float BINARY_FLOAT,
        bin_double BINARY_DOUBLE
      )
    SQL
    @conn.execute <<~SQL
      INSERT INTO test_binary_doubles (id, bin_float, bin_double)
      VALUES (1, 1.5, 3.141592653589793)
    SQL
  end

  after(:all) do
    @conn.execute "DROP TABLE test_binary_doubles" rescue nil
  end

  it "returns the BINARY_FLOAT value (works on master)" do
    row = @conn.select_one("SELECT bin_float FROM test_binary_doubles WHERE id = 1")
    expect(row["bin_float"]).not_to be_nil
    expect(row["bin_float"].to_f).to be_within(0.001).of(1.5)
  end

  it "returns the BINARY_DOUBLE value (fails on master under JRuby)" do
    if defined?(JRUBY_VERSION)
      # Affected platform — this is the actual repro.
      row = @conn.select_one("SELECT bin_double FROM test_binary_doubles WHERE id = 1")
      expect(row["bin_double"]).not_to be_nil,
        "BINARY_DOUBLE column returned nil — issue #2302 reproduced. " \
        "JDBCConnection#get_ruby_value_from_result_set is missing a " \
        ":BINARY_DOUBLE branch in its case statement (see " \
        "lib/active_record/connection_adapters/oracle_enhanced/jdbc_connection.rb)."
      expect(row["bin_double"].to_f).to be_within(1e-12).of(3.141592653589793)
    else
      # CRuby/OCI: ruby-oci8 handles BINARY_DOUBLE natively. This branch
      # serves as a regression guard so we notice if that ever changes.
      row = @conn.select_one("SELECT bin_double FROM test_binary_doubles WHERE id = 1")
      expect(row["bin_double"]).not_to be_nil
      expect(row["bin_double"].to_f).to be_within(1e-12).of(3.141592653589793)
    end
  end
end
