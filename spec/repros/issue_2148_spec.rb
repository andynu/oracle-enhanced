# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2148
#
# Title: remove_index does not work in Rails 6.1.2 migrations if both column
#        and index name are given
#
# URL: https://github.com/rsim/oracle-enhanced/issues/2148
#
# Summary
# -------
# When `remove_index` is called with BOTH a column and an explicit `:name`
# option (the form Rails 6.1+ uses when reversing
# `add_index :table, [:col], name: 'IX_FOO'`), the adapter raises
#   ArgumentError: No indexes found on <table> with the options provided.
# even though the index exists.
#
# Root cause (per issue comments): the abstract adapter's
# `index_name_for_remove` requires BOTH the column-list and the name to match,
# but `indexes(table_name)` from oracle_enhanced returns column names in
# uppercase / different formatting, so the predicate `checks.all?` returns
# empty.
#
# Status (on master @ e8e1677c, ActiveRecord master from rails/rails git):
#   REPRODUCED. 3 examples, 1 failure.
#
#   The two control cases pass:
#     - remove_index :table, name: "IX_FOO"            (name only)
#     - remove_index :table, :col                       (column only)
#
#   The bug case fails with:
#     ArgumentError:
#       No indexes found on issue_2148_dummy with the options provided.
#     raised from
#       active_record/connection_adapters/abstract/schema_statements.rb
#       in index_name_for_remove
#
#   This matches the upstream reproduction in the issue, where Rails 6.1's
#   reverse of `add_index :tbl, [:col], name: 'IX_FOO'` calls
#     remove_index :tbl, :col, name: 'IX_FOO'
#   and the adapter cannot resolve the index.

RSpec.describe "issue #2148: remove_index with column and name" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
  end

  before do
    @conn.create_table :issue_2148_dummy, force: true do |t|
      t.string :name
    end
  end

  after do
    @conn.drop_table :issue_2148_dummy, if_exists: true
  end

  it "remove_index works with only :name (control case)" do
    @conn.add_index :issue_2148_dummy, :name, name: "IX_DUMMY_NAME_A"
    expect {
      @conn.remove_index :issue_2148_dummy, name: "IX_DUMMY_NAME_A"
    }.not_to raise_error
  end

  it "remove_index works with only column (control case)" do
    @conn.add_index :issue_2148_dummy, :name, name: "IX_DUMMY_NAME_B"
    expect {
      @conn.remove_index :issue_2148_dummy, :name
    }.not_to raise_error
  end

  it "remove_index works when given both column and :name (the bug)" do
    @conn.add_index :issue_2148_dummy, :name, name: "IX_DUMMY_NAME_C"
    expect {
      @conn.remove_index :issue_2148_dummy, :name, name: "IX_DUMMY_NAME_C"
    }.not_to raise_error
  end
end
