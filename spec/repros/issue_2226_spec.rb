# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2226
# Title:  "#write_lobs called only on update but not on create"
# URL:    https://github.com/rsim/oracle-enhanced/issues/2226
# Reported against: master (circa 2021), Ruby 2.7.3, Oracle 19.3.0
#
# Summary of the report:
#   The reporter observed that #write_lobs was called on UPDATE but not on
#   CREATE. At the time, lib/.../oracle_enhanced/lob.rb registered only:
#       before_update  :record_changed_lobs
#       after_update   :enhanced_write_lobs
#   ...so when prepared_statements was disabled (or otherwise routed through
#   the write_lobs codepath), CREATE inserted an empty/placeholder LOB and the
#   actual data was never written back. INSERTs went through but the LOB
#   content ended up truncated or empty.
#
# Expected behavior:
#   After Model.create!(clob_col: large_text), a re-fetch should return the
#   exact same string.
#
# Actual behavior (at time of report):
#   The post-INSERT "SELECT ... FOR UPDATE" round-trip that updates the LOB
#   payload was skipped on create, so the column came back empty (or with the
#   placeholder bind value, depending on adapter mode).
#
# Status (on master @ e8e1677c, Rails 8.2.0.alpha, Ruby 4.0.1, Oracle 21c XE):
#   BOTH EXAMPLES PASS -- the bug is not reproducible. Looking at
#   lib/active_record/connection_adapters/oracle_enhanced/lob.rb on master:
#       before_create :record_lobs_for_create
#       after_create  :enhanced_write_lobs
#       before_update :record_changed_lobs
#       after_update  :enhanced_write_lobs
#   ...both the create and the update paths now run write_lobs when needed.
#   Subsequent commits (9bce3e3c, 33d61a1f, 65089857, 9bce3e3c, d5d1eab1)
#   hardened the prepared_statements=false path specifically. Keeping this
#   spec as a regression guard for both the default (prepared_statements=true)
#   path and the historical bug path (prepared_statements=false).

require "spec_helper"

RSpec.describe "Issue #2226: #write_lobs called only on update but not on create" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    @conn.execute "DROP TABLE issue_2226_docs" rescue nil
    @conn.execute "DROP SEQUENCE issue_2226_docs_seq" rescue nil
    @conn.execute <<~SQL
      CREATE TABLE issue_2226_docs (
        id   NUMBER(10) PRIMARY KEY,
        name VARCHAR2(50),
        body CLOB
      )
    SQL
    @conn.execute "CREATE SEQUENCE issue_2226_docs_seq START WITH 1"
  end

  after(:all) do
    @conn.execute "DROP TABLE issue_2226_docs" rescue nil
    @conn.execute "DROP SEQUENCE issue_2226_docs_seq" rescue nil
  end

  before(:each) do
    stub_const("Issue2226Doc", Class.new(ActiveRecord::Base) do
      self.table_name = "issue_2226_docs"
    end)
    Issue2226Doc.delete_all
  end

  # A payload comfortably larger than Oracle's inline VARCHAR2 cutoff
  # (4000 bytes) so the value must traverse the actual LOB binding/write path.
  let(:large_body) { "abcdefghij" * 1000 } # 10_000 chars

  context "with prepared_statements enabled (default)" do
    it "Model.create! persists the full CLOB payload" do
      Issue2226Doc.create!(id: 1, name: "first", body: large_body)
      reloaded = Issue2226Doc.find(1)
      expect(reloaded.body.length).to eq(large_body.length)
      expect(reloaded.body).to eq(large_body)
    end
  end

  context "with prepared_statements disabled (the historical bug path)" do
    around(:each) do |example|
      old_prepared_statements = @conn.prepared_statements
      @conn.instance_variable_set(:@prepared_statements, false)
      example.run
      @conn.instance_variable_set(:@prepared_statements, old_prepared_statements)
    end

    it "Model.create! persists the full CLOB payload via write_lobs" do
      Issue2226Doc.create!(id: 2, name: "second", body: large_body)
      reloaded = Issue2226Doc.find(2)
      expect(reloaded.body.length).to eq(large_body.length)
      expect(reloaded.body).to eq(large_body)
    end
  end
end

# ---------------------------------------------------------------------------
# Reproduction status on master @ e8e1677c (Rails 8.2.0.alpha, Ruby 4.0.1,
# Oracle 21c XE):
#
#   $ bundle exec rspec spec/repros/issue_2226_spec.rb
#   Issue #2226: #write_lobs called only on update but not on create
#     with prepared_statements enabled (default)
#       Model.create! persists the full CLOB payload
#     with prepared_statements disabled (the historical bug path)
#       Model.create! persists the full CLOB payload via write_lobs
#   Finished in 0.26s
#   2 examples, 0 failures
#
#   Conclusion: NOT REPRODUCIBLE on master. Issue #2226 appears resolved by
#   commit c5c68fe3 ("Introduce OracleEnhanced::Lob ...") and the subsequent
#   prepared_statements=false hardening series.
# ---------------------------------------------------------------------------
