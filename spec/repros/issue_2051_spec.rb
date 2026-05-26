# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2051
# Title: add_synonym with database link
# URL: https://github.com/rsim/oracle-enhanced/issues/2051
# Status: reproduced
# Notes: The reporter calls `add_synonym "new_synonym", "other_user.table@dblink"`
#   and Oracle creates a synonym, but the `@dblink` suffix is silently
#   stripped, so the synonym points to a local (and almost always
#   non-existent) `OTHER_USER.TABLE`. The downstream symptom is an
#   opaque `"DESC OTHER_USER.TABLE" failed; does it exist?` from
#   ActiveRecord against a model that uses the synonym -- a long way
#   from the migration that created the broken synonym.
#
#   Mechanism: schema_statements.rb#add_synonym builds the SQL with
#   `quote_table_name(table_name)`. quoting.rb#quote_table_name does:
#
#     def quote_table_name(name)
#       name, _link = name.to_s.split("@")
#       QUOTED_TABLE_NAMES[name] ||=
#         [name.split(".").map { |n| quote_column_name(n) }].join(".")
#     end
#
#   The `_link` is discarded with no warning and no error. This is the
#   behaviour the reporter calls out: either keep the dblink (preferred,
#   restoring the pre-#1668 behaviour) or raise so the caller's bug is
#   surfaced at migration time rather than at first model query.
#
#   The reporter's preferred outcome is "raise an error" -- we encode
#   that as the failing assertion below. There is no `db_link:` option
#   on `add_synonym` and no support for the `@dblink` suffix surviving
#   `quote_table_name`; this spec documents both gaps.
#
#   Why we don't actually CREATE the synonym with a dblink in the
#   live-DB test: the local Docker XE has no database link defined, and
#   `CREATE DATABASE LINK` requires CREATE DATABASE LINK privileges
#   plus a real remote target. We instead inspect the SQL that the
#   adapter would emit, which is sufficient to demonstrate the silent
#   drop, and pair it with a live execute that confirms the resulting
#   synonym is broken in exactly the way the reporter describes
#   (USER_SYNONYMS row with DB_LINK column NULL).

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2051: add_synonym silently drops @dblink suffix" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
  end

  after(:all) do
    # Cleanup any synonyms this spec created. Use drop_if_exists so a
    # failure mid-test does not leave artefacts behind.
    @conn.drop_if_exists("SYNONYM", "issue_2051_synonym") if @conn
  end

  describe "quote_table_name (the proximate cause)" do
    it "silently drops the @dblink suffix instead of preserving or raising" do
      quoted = @conn.quote_table_name("other_user.table@some_dblink")

      # Demonstrates the bug: the @some_dblink portion is gone.
      expect(quoted).not_to include("some_dblink")
      expect(quoted).not_to include("@")

      # What the reporter (and we) think SHOULD happen -- either of:
      #   (a) the dblink survives quoting:
      #         expect(quoted).to include("@SOME_DBLINK") or similar
      #   (b) quote_table_name raises so the caller knows their input
      #       was non-portable:
      #         expect { @conn.quote_table_name(...) }.to raise_error(...)
      #
      # Neither is true today. We assert (b) as the failing expectation
      # because issue #2051 explicitly proposes raising; (a) is the
      # competing design but is a larger surface change (restoring
      # dblink support gem-wide, reverting parts of #1668).
      expect {
        @conn.quote_table_name("other_user.table@some_dblink")
      }.to raise_error(ArgumentError, /database link|dblink|@/i),
        "quote_table_name silently dropped the @dblink instead of raising; " \
        "this is the root cause of #2051. Expected an ArgumentError so " \
        "the calling migration fails fast rather than producing a synonym " \
        "that points to a non-existent local object."
    end
  end

  describe "add_synonym (the user-visible surface)" do
    it "has no db_link: option and no surviving @dblink syntax" do
      # The method signature is `add_synonym(name, table_name, options = {})`.
      # There is no documented or undocumented `db_link:` option, and the
      # `@dblink` suffix in the table_name is stripped by quote_table_name
      # before the CREATE SYNONYM statement is built. This expectation
      # captures the missing API as a failing test.
      method = @conn.method(:add_synonym)
      param_names = method.parameters.map { |_, name| name }
      expect(param_names).to include(:db_link),
        "add_synonym(name, table_name, options = {}) accepts no db_link " \
        "parameter. Issue #2051 asks for either a db_link option or for " \
        "the @dblink suffix in table_name to be preserved/rejected. " \
        "Today neither path exists -- the dblink is silently dropped."
    end

    it "produces a synonym whose USER_SYNONYMS.DB_LINK is NULL (live DB)" do
      # End-to-end demonstration. We point the synonym at a real local
      # table (USER_TABLES) so the CREATE succeeds; the bug is that the
      # @bogus_link suffix is silently dropped, not that the synonym
      # fails to create. The reporter's pain is exactly this: the create
      # succeeds, the synonym looks plausible, and the breakage shows up
      # later when something queries through it.
      @conn.execute(
        "CREATE OR REPLACE SYNONYM issue_2051_synonym FOR " \
        "#{@conn.quote_table_name('user_tables@bogus_link')}"
      )

      row = @conn.select_one(<<~SQL)
        SELECT table_name, db_link
        FROM user_synonyms
        WHERE synonym_name = 'ISSUE_2051_SYNONYM'
      SQL

      expect(row).not_to be_nil
      # The DB_LINK column being NULL is the smoking gun: the user asked
      # for a remote object via @bogus_link, Oracle would normally accept
      # the syntax (and validate the link lazily), but the adapter
      # stripped the suffix before the SQL ever reached Oracle.
      expect(row["db_link"]).not_to be_nil,
        "USER_SYNONYMS.DB_LINK is NULL -- the adapter dropped @bogus_link " \
        "before issuing CREATE SYNONYM. Issue #2051: this is what causes " \
        "the misleading 'DESC OTHER_USER.TABLE failed; does it exist?' " \
        "error later, because the synonym now points at a local object " \
        "that does not exist instead of a remote one that does."
    end
  end
end
