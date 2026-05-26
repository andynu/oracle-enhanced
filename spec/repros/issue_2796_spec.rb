# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2796
# Title: Translate Arel-level .returning(...) to Oracle's RETURNING ... INTO :bind for direct-Arel callers (Rails #47161)
# URL: https://github.com/rsim/oracle-enhanced/issues/2796
# Status: reproduced
# Notes: Rails 8.2.0.alpha (with rails/rails#47161 merged) exposes a chainable
#   Arel `.returning(...)` API on Insert/Update/Delete managers. The default
#   Arel::Visitors::ToSql appends a PostgreSQL-style `RETURNING <expr-list>`
#   when the statement node's `returning` attribute is non-empty.
#
#   oracle-enhanced's Arel::Visitors::Oracle12 (and Oracle) do NOT override
#   visit_Arel_Nodes_InsertStatement / visit_Arel_Nodes_DeleteStatement, and
#   OracleCommon#visit_Arel_Nodes_UpdateStatement only strips ORDER BY before
#   delegating to super. Result: the PostgreSQL-style `RETURNING ...` clause
#   flows through unchanged.
#
#   The spec compiles SQL via `connection.to_sql` for direct-Arel INSERT /
#   UPDATE / DELETE managers with `.returning(Arel.star)`, asserts the
#   emitted SQL still contains the PostgreSQL form (`RETURNING *`) and lacks
#   Oracle's `INTO :bind` form, and confirms Oracle rejects it at execute
#   time with an ORA error. This is the failure mode the upstream ticket
#   describes; no translation/raise is in place today, so the tests pass —
#   they document the problem and will FAIL once oracle-enhanced
#   implements option (a) "translate" or option (b) "raise". At that point
#   these reproduction assertions should be inverted into a regression test
#   for the chosen behavior.

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2796: direct-Arel .returning(...) on Oracle" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection

    # Skip cleanly if running against an older Rails/Arel without the
    # .returning API (rails/rails#47161). The issue only manifests with
    # that API available.
    skip "Arel does not expose .returning in this Rails version" unless Arel::InsertManager.instance_method(:returning) rescue skip("Arel.returning unavailable")

    @conn.execute("DROP TABLE test_issue_2796_items") rescue nil
    @conn.execute(<<~SQL)
      CREATE TABLE test_issue_2796_items (
        id        NUMBER(38) PRIMARY KEY,
        name      VARCHAR2(50),
        priority  NUMBER(38)
      )
    SQL
  end

  after(:all) do
    @conn.execute("DROP TABLE test_issue_2796_items") rescue nil
  end

  let(:conn) { @conn }
  let(:table) { Arel::Table.new(:test_issue_2796_items) }

  describe "INSERT with Arel#returning(Arel.star)" do
    it "currently emits PostgreSQL-style `RETURNING *` instead of Oracle's `RETURNING ... INTO :bind`" do
      im = Arel::InsertManager.new.into(table)
      im.insert([[table[:id], 1], [table[:name], "alpha"]])
      im.returning(Arel.star)

      sql = conn.to_sql(im.ast)

      # Reproduction: the PostgreSQL-style clause leaks through unchanged.
      expect(sql).to match(/RETURNING\s+\*/i),
        "Expected PostgreSQL-style RETURNING * to leak through (reproducing #2796); got: #{sql}"

      # And the Oracle form is NOT produced.
      expect(sql).not_to match(/RETURNING\s+.*INTO\s+:/i),
        "Expected NO Oracle-style RETURNING ... INTO :bind today (reproducing #2796); got: #{sql}"
    end

    it "Oracle rejects the resulting SQL at execute time (no translation, no pre-flight raise)" do
      im = Arel::InsertManager.new.into(table)
      im.insert([[table[:id], 2], [table[:name], "beta"]])
      im.returning(Arel.star)

      sql = conn.to_sql(im.ast)

      # Today: neither option (a) "translate" nor option (b) "raise" is
      # implemented, so the failure is whatever Oracle says about the bare
      # PostgreSQL-shaped SQL. ActiveRecord::StatementInvalid wraps it.
      expect { conn.execute(sql) }.to raise_error(ActiveRecord::StatementInvalid) do |err|
        # ORA-00933: SQL command not properly ended (RETURNING * is unparseable)
        # is the typical surface, but the exact ORA code is not load-bearing —
        # what matters is that we get a parse error from the server rather
        # than a translated, working statement or a clear NotImplementedError.
        expect(err.message).to match(/ORA-\d{5}/),
          "Expected an ORA-NNNNN parse error from Oracle (reproducing #2796); got: #{err.message}"
      end
    end
  end

  describe "UPDATE with Arel#returning(Arel.star)" do
    before do
      conn.execute("DELETE FROM test_issue_2796_items")
      conn.execute("INSERT INTO test_issue_2796_items (id, name, priority) VALUES (10, 'orig', 1)")
    end

    it "currently emits PostgreSQL-style `RETURNING *` (UpdateStatement visitor strips ORDER BY only)" do
      um = Arel::UpdateManager.new
      um.table(table)
      um.set([[table[:name], "updated"]])
      um.where(table[:id].eq(10))
      um.returning(Arel.star)

      sql = conn.to_sql(um.ast)

      expect(sql).to match(/RETURNING\s+\*/i),
        "Expected PostgreSQL-style RETURNING * to leak through UPDATE (reproducing #2796); got: #{sql}"
      expect(sql).not_to match(/RETURNING\s+.*INTO\s+:/i)
    end
  end

  describe "DELETE with Arel#returning(Arel.star)" do
    before do
      conn.execute("DELETE FROM test_issue_2796_items")
      conn.execute("INSERT INTO test_issue_2796_items (id, name, priority) VALUES (20, 'to_delete', 1)")
    end

    it "currently emits PostgreSQL-style `RETURNING *` (no DeleteStatement override)" do
      dm = Arel::DeleteManager.new
      dm.from(table)
      dm.where(table[:id].eq(20))
      dm.returning(Arel.star)

      sql = conn.to_sql(dm.ast)

      expect(sql).to match(/RETURNING\s+\*/i),
        "Expected PostgreSQL-style RETURNING * to leak through DELETE (reproducing #2796); got: #{sql}"
      expect(sql).not_to match(/RETURNING\s+.*INTO\s+:/i)
    end
  end

  describe "Sanity: AR-driven inserts still go through sql_for_insert (NOT affected by this issue)" do
    # Per the issue body: "There's no regression today — AR-driven INSERT
    # continues to go through OracleEnhanced::DatabaseStatements#sql_for_insert,
    # which uses Oracle's RETURNING INTO form."
    #
    # This is documentation, not an assertion of the issue itself. We use
    # raw execute so this works without an AR model definition leak.
    it "AR-driven inserts are unaffected (sanity check, not a repro)" do
      # An AR-style insert via raw SQL has no Arel .returning() — it goes
      # through the adapter's own sql_for_insert path. We just confirm a
      # plain insert/select round-trip works on the test table.
      conn.execute("DELETE FROM test_issue_2796_items")
      conn.execute("INSERT INTO test_issue_2796_items (id, name) VALUES (99, 'ar_path')")
      row = conn.select_one("SELECT name FROM test_issue_2796_items WHERE id = 99")
      expect(row["name"]).to eq("ar_path")
    end
  end
end
