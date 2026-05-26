# frozen_string_literal: true

# Reproduction for upstream issue rsim/oracle-enhanced#2410
#
# Title: "7.1 update: strange serialize behavior"
# URL:   https://github.com/rsim/oracle-enhanced/issues/2410
#
# Symptom (Rails 7.1, oracle-enhanced 7.1.0+):
#   For a model with `serialize :col, type: Hash, coder: YAML` backed by a
#   CLOB column, `Model.where(col: nil)` no longer compiles to
#   "WHERE col IS NULL". Instead it generates
#       WHERE DBMS_LOB.COMPARE(col, NULL) = 0
#   which Oracle evaluates to NULL (not TRUE) for every row, so the result
#   is always 0 rows -- even when the column is genuinely NULL.
#
#   The raw-SQL form `where("col is NULL")` still works, but the
#   conventional `where(col: nil)` predicate is broken.
#
# Status on this branch (master @ e8e1677c): reproduces. The
# DBMS_LOB.COMPARE rewrite happens via the adapter's Quoting/visitor
# treatment of TEXT/CLOB equality, and it now incorrectly fires for the
# `IS NULL` case as well.

require "spec_helper"

RSpec.describe "Issue #2410: serialize + where(col: nil) on CLOB" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    schema_define do
      create_table :issue_2410_models, force: true do |t|
        t.string :name, limit: 50
        t.text   :something
      end
    end

    class ::Issue2410Model < ActiveRecord::Base
      self.table_name = "issue_2410_models"
      serialize :something, type: Hash, coder: YAML
    end
  end

  after(:all) do
    @conn.drop_table :issue_2410_models, if_exists: true
    Object.send(:remove_const, "Issue2410Model") if defined?(::Issue2410Model)
    ActiveRecord::Base.clear_cache!
  end

  before do
    Issue2410Model.delete_all
    # Three rows with `something` NULL; one row with a real serialized Hash.
    Issue2410Model.create!(name: "a")
    Issue2410Model.create!(name: "b")
    Issue2410Model.create!(name: "c")
    Issue2410Model.create!(name: "d", something: { foo: "bar" })
  end

  it "counts NULL rows via raw SQL (sanity check)" do
    expect(Issue2410Model.where("something IS NULL").count).to eq(3)
  end

  it "compiles where(something: nil) to a plain IS NULL predicate" do
    sql = Issue2410Model.where(something: nil).to_sql
    # The bug: the generated SQL contains DBMS_LOB.COMPARE(..., NULL) = 0,
    # which Oracle always evaluates to NULL -> the predicate matches nothing.
    expect(sql).not_to match(/DBMS_LOB\.COMPARE/i),
      "expected IS NULL predicate, got: #{sql}"
    expect(sql).to match(/IS NULL/i)
  end

  it "where(something: nil) returns the NULL rows" do
    # On 7.1.x this returns 0 instead of 3.
    expect(Issue2410Model.where(something: nil).count).to eq(3)
  end

  it "where(something: {}) returns the NULL rows (empty Hash serializes to nil/empty)" do
    # Same DBMS_LOB.COMPARE path; on 7.1.x this also returns 0.
    expect(Issue2410Model.where(something: {}).count).to eq(3)
  end
end
