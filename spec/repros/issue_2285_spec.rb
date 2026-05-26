# frozen_string_literal: true

# Repro for rsim/oracle-enhanced#2285
# "ActiveRecord::ConnectionAdapters::OracleEnhanced::SchemaStatements#table_comment
#  not working correctly in 6.x"
# https://github.com/rsim/oracle-enhanced/issues/2285
#
# Behavior reported by the original filer (oracle_enhanced 6.x):
#   When a model lives in a non-default schema and #table_comment is called
#   with the schema-qualified table name (e.g. "my_schema.my_model"),
#   #table_comment returns nil. In 5.2.x it correctly returned the comment.
#
# Root cause hypothesis (still present on master at HEAD as of this repro):
#   SchemaStatements#table_comment runs `resolve_data_source_name(table_name)`
#   to split out the owner from the qualified name, then assigns the owner to
#   `_owner` (discarded) and queries `all_tab_comments WHERE owner =
#   SYS_CONTEXT('userenv', 'current_schema')`. The discovered owner is never
#   used — so a comment that exists in another schema is invisible.
#
# Status on master HEAD (e8e1677c) confirmed against Oracle XE 21c:
#   - table_comment("oracle_enhanced_schema.issue_2285_table") returns nil
#   - expected "This model has a comment"
#   - bug is still present, fix has not been merged

require "spec_helper"

RSpec.describe "Issue #2285: table_comment with schema-qualified table name" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection

    # Use the secondary schema set up by the project's test harness.
    # spec/spec_helper.rb defines DATABASE_SCHEMA (default
    # "oracle_enhanced_schema") and creates the corresponding Oracle user.
    @other_schema = DATABASE_SCHEMA
    @table        = "issue_2285_table"
    @qualified    = "#{@other_schema}.#{@table}"
    @comment      = "This model has a comment"

    # Create the table in the *other* schema, owned by that schema's user.
    # We do this via a connection logged in as that user so the comment lives
    # under owner = DATABASE_SCHEMA, NOT the primary test user.
    schema_owner_params = CONNECTION_PARAMS.merge(
      username: @other_schema, password: @other_schema
    )
    ActiveRecord::Base.establish_connection(schema_owner_params)
    other_conn = ActiveRecord::Base.lease_connection
    other_conn.drop_table @table, if_exists: true
    other_conn.create_table @table, comment: @comment do |t|
      t.string :name
    end
    # Let the primary user at least see metadata.
    other_conn.execute "GRANT SELECT ON #{@table} TO #{DATABASE_USER}"
    ActiveRecord::Base.remove_connection

    # Switch back to the primary test user (the one the bug report uses).
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
  end

  after(:all) do
    # Drop from the owning schema.
    schema_owner_params = CONNECTION_PARAMS.merge(
      username: @other_schema, password: @other_schema
    )
    ActiveRecord::Base.remove_connection
    ActiveRecord::Base.establish_connection(schema_owner_params)
    ActiveRecord::Base.lease_connection.drop_table @table, if_exists: true
    ActiveRecord::Base.remove_connection
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
  end

  it "returns the table comment when given a schema-qualified name" do
    # This is the assertion that fails per the bug report: in 6.x and on
    # master, #table_comment returns nil because it filters owner by the
    # CURRENT_SCHEMA of the calling session, ignoring the owner parsed out of
    # the qualified name.
    expect(@conn.table_comment(@qualified)).to eq(@comment)
  end
end
