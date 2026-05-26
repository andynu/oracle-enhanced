# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2213
# Title: Include check constraints in structure.sql
# URL: https://github.com/rsim/oracle-enhanced/issues/2213
# Status: fixed_on_master
# Notes:
#   The issue reports that after defining a CHECK constraint via raw SQL
#   in a migration (e.g.
#     `ALTER TABLE test_posts ADD CONSTRAINT foo_is_json CHECK(foo IS JSON)`)
#   and running `db:migrate` with
#   `config.active_record.schema_format = :sql`, the CHECK constraint is
#   omitted from db/structure.sql.
#
#   On master the adapter has two structure-dump backends, both routed
#   through ConnectionAdapters::OracleEnhanced::StructureDump::Dispatcher
#   (see lib/active_record/connection_adapters/oracle_enhanced/
#   structure_dump/dispatcher.rb):
#
#   * `:data_dictionary` — assembles DDL from ALL_* views in Ruby. The
#     `structure_dump` method calls `structure_dump_check_constraints`,
#     which queries `all_constraints` for rows with
#     `constraint_type = 'C'` and `generated = 'USER NAME'` (skipping
#     implicit NOT-NULL checks) and emits
#       ALTER TABLE "T" ADD CONSTRAINT "N" CHECK (<condition>)
#     statements. Added in PR #2500
#     (commit 781e53e5, "Include check constraints in structure dump").
#
#   * `:dbms_metadata` — delegates to Oracle's DBMS_METADATA.GET_DDL.
#     Oracle emits the CHECK clause inline inside the CREATE TABLE,
#     for example:
#       CONSTRAINT "ISSUE_2213_RATING_RANGE" CHECK (rating BETWEEN 1 AND 5) ENABLE
#
#   This spec exercises both backends and asserts that the dump mentions
#   the user-named CHECK constraint and its condition, regardless of which
#   syntactic form Oracle picked. On 8.0.0 / Rails 6.1 (the issue's
#   configuration) the constraint was missing entirely; on master both
#   paths include it.

require "spec_helper"

RSpec.describe "Issue #2213: structure_dump must include CHECK constraints" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    schema_define do
      create_table :test_issue_2213_posts, force: true do |t|
        t.string :title
        t.integer :rating
      end
    end
    @conn.execute(
      "ALTER TABLE test_issue_2213_posts " \
      "ADD CONSTRAINT issue_2213_rating_range CHECK (rating BETWEEN 1 AND 5)"
    )
  end

  after(:all) do
    @conn = ActiveRecord::Base.lease_connection
    @conn.drop_table :test_issue_2213_posts, if_exists: true
    ActiveRecord::Base.clear_cache!
  end

  around(:each) do |example|
    adapter_class = ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter
    saved = adapter_class.structure_dump_method
    begin
      example.run
    ensure
      adapter_class.structure_dump_method = saved
    end
  end

  shared_examples "dumps the CHECK constraint" do |backend|
    it "includes the user-named CHECK constraint and its condition (#{backend})" do
      ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter
        .structure_dump_method = backend

      dump = ActiveRecord::Base.lease_connection.structure_dump

      expect(dump).to match(/test_issue_2213_posts/i)
      expect(dump).to match(/issue_2213_rating_range/i)
      expect(dump).to match(/CHECK\s*\(\s*rating\s+BETWEEN\s+1\s+AND\s+5/i)
    end
  end

  include_examples "dumps the CHECK constraint", :data_dictionary
  include_examples "dumps the CHECK constraint", :dbms_metadata
end
