# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2343
# "ActiveRecord::ConnectionAdapters::OracleEnhanced::Connection::describe
#  can fail for long table/view names"
#
# https://github.com/rsim/oracle-enhanced/issues/2343
#
# Summary of the upstream complaint
# ---------------------------------
# Oracle 12.2+ allows identifiers up to 128 bytes, but the old
# Quoting::VALID_TABLE_NAME regex hard-coded a {0,29} byte bound. As a
# result `OracleEnhanced::Quoting.valid_table_name?` returned false for a
# 31+ character lowercase identifier, callers stopped upcasing the name,
# and downstream DBMS_UTILITY.NAME_RESOLVE (or DESC) blew up with
# `ConnectionException("DESC <name>" failed; does it exist?)`.
#
# The user's reproduction (Rails 6.1.7.3, oracle_enhanced 6.1.6):
#   self.table_name = 'a_table_or_view_name_longer_than_thirty_characters'  # fails
#   self.table_name = 'a_table_or_view_name_longer_than_thirty_characters'.upcase # works
#   self.table_name = 'a_short_table_or_view_name'                         # works
#
# Status on master as of this branch
# ----------------------------------
# Confirmed FIXED on master against Oracle XE 21.x.
# The grammar in `valid_table_name?` has been rewritten to take the byte
# limit as a parameter (defaulting to the connection's
# `max_identifier_length`, 128 on Oracle 12.2+ where COMPATIBLE >= 12.2).
# Callers in `schema_statements.rb` (`table_exists?`, `data_source_exists?`,
# `resolve_data_source_name`, `extract_schema_qualified_name`) all pass
# `max_identifier_length: max_identifier_length` through.
#
# These specs are written as **green guard tests** (all 8 pass) that
# exercise the previously-failing paths end-to-end against the live
# database. Any regression that reintroduces a 30-byte cap will surface
# as failures in the `data_source_exists?` and `columns` assertions —
# those are the same paths the original bug report blew up on.
#
# What this spec exercises
# ------------------------
# - `OracleEnhanced::Quoting.valid_table_name?` accepts a 50-char
#   lowercase identifier when `max_identifier_length: 128` is passed.
# - `connection.table_exists?` returns true for the long lowercase name.
# - `connection.data_source_exists?` (which calls
#   `resolve_data_source_name` -> NAME_RESOLVE under the hood) returns
#   true for the long lowercase name. This is the precise call path the
#   original bug report fails on.
# - An ActiveRecord model with `self.table_name = '<50-char lowercase>'`
#   can load its column metadata. This mirrors the user-facing repro
#   (`TestModel` accessed after assigning `self.table_name`).

require "spec_helper"

RSpec.describe "Issue #2343: describe fails for long lowercase table names" do
  # 50 characters: well over the legacy 30-byte cap, well under the
  # modern 128-byte cap.
  let(:long_table_name) { "a_table_or_view_name_longer_than_thirty_characters" }
  let(:short_table_name) { "a_short_table_or_view_name" }

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    conn = ActiveRecord::Base.lease_connection
    # Recreate cleanly in case a previous run left them around.
    %w[a_table_or_view_name_longer_than_thirty_characters a_short_table_or_view_name].each do |t|
      conn.drop_table(t) rescue nil
      conn.create_table(t) { |x| x.string :name }
    end
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    %w[a_table_or_view_name_longer_than_thirty_characters a_short_table_or_view_name].each do |t|
      conn.drop_table(t) rescue nil
    end
  end

  let(:connection) { ActiveRecord::Base.lease_connection }

  it "reports the connection's max_identifier_length is > 30 on Oracle 12.2+" do
    # Sanity: the fix only kicks in when the connection advertises a
    # length > 30. If this is somehow 30 the rest of the spec is moot.
    expect(connection.max_identifier_length).to be > 30
  end

  describe "Quoting.valid_table_name?" do
    it "accepts a 50-char lowercase identifier with max_identifier_length: 128" do
      expect(
        ActiveRecord::ConnectionAdapters::OracleEnhanced::Quoting.valid_table_name?(
          long_table_name, max_identifier_length: 128
        )
      ).to be true
    end

    it "rejects the same identifier when max_identifier_length: 30 (legacy cap)" do
      expect(
        ActiveRecord::ConnectionAdapters::OracleEnhanced::Quoting.valid_table_name?(
          long_table_name, max_identifier_length: 30
        )
      ).to be false
    end
  end

  describe "connection.table_exists?" do
    it "finds the long lowercase table" do
      expect(connection.table_exists?(long_table_name)).to be true
    end

    it "finds the long UPCASED table (worked even on the broken version)" do
      expect(connection.table_exists?(long_table_name.upcase)).to be true
    end

    it "finds the short lowercase table (worked even on the broken version)" do
      expect(connection.table_exists?(short_table_name)).to be true
    end
  end

  describe "connection.data_source_exists? (calls resolve_data_source_name -> NAME_RESOLVE)" do
    # This is the exact failure path from the issue: accessing a model
    # with `self.table_name = '<long lowercase>'` walks through
    # `resolve_data_source_name`, which is where the original bug
    # raised `ConnectionException("DESC ...")`.
    it "resolves the long lowercase table without raising" do
      expect { connection.data_source_exists?(long_table_name) }.not_to raise_error
      expect(connection.data_source_exists?(long_table_name)).to be true
    end
  end

  describe "ActiveRecord model with long lowercase table_name" do
    it "loads column metadata without ConnectionException" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "a_table_or_view_name_longer_than_thirty_characters"
      end
      expect { klass.columns }.not_to raise_error
      expect(klass.columns.map(&:name)).to include("name")
    end
  end
end
