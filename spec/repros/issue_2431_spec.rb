# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2431
# "[Bug] Adapter 7.1.0 ignores self.sequence_name, includes ID in INSERT
#  instead of using RETURNING ID (Rails 7.1)"
# https://github.com/rsim/oracle-enhanced/issues/2431
#
# Reporter symptom (adapter 7.1.0, Rails 7.1):
#   - Model declares `self.sequence_name = "..."` for a custom Oracle sequence.
#   - On `Model.create!`, the adapter does `SELECT seq.nextval FROM DUAL` and
#     binds the value into the INSERT's VALUES list (column "ID" present).
#   - The INSERT succeeds and the row exists in the DB with the sequence-fetched
#     ID, but the in-memory AR object's `id` attribute is left `nil`.
#   - Subsequent `redirect_to @record` / `record.reload` lookups blow up
#     because the object thinks it has no primary key.
#
# Reporter noted in a follow-up comment that the problem is gone in 8.0.0,
# so on current master (8.2.0.alpha) this spec is expected to PASS — it
# locks in the post-fix behavior:
#
#   (a) The issued INSERT against the custom-sequence table goes through the
#       sequence-prefetch path (column "ID" bound into VALUES; RETURNING ... INTO
#       is NOT emitted — that is oracle-enhanced's default contract for the
#       non-identity path and is asserted elsewhere in the suite).
#   (b) After `create!`, the in-memory object's `id` is populated and matches
#       the row actually written to the database. This is the assertion that
#       would have failed on 7.1.0.
#
# Status: PASSING on master; would have FAILED on 7.1.0.
#
# Unique table + sequence names with timestamps so repeated runs don't collide
# with leftovers from a previously aborted run.

require "spec_helper"

RSpec.describe "Issue #2431: self.sequence_name with custom Oracle sequence" do
  include LoggerSpecHelper
  include SchemaSpecHelper

  TABLE_2431    = :issue_2431_categories
  SEQUENCE_2431 = "issue_2431_cat_seq"

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection

    # Drop any stale fixtures from a previous aborted run before recreating.
    # create_table auto-creates `<TABLE>_SEQ` for the PK, so drop both possible
    # sequences (the auto-derived one and our explicit custom sequence) to
    # avoid ORA-00955 ("name is already used") on rerun.
    @conn.execute("DROP TABLE #{TABLE_2431.to_s.upcase}") rescue nil
    @conn.execute("DROP SEQUENCE #{TABLE_2431.to_s.upcase}_SEQ") rescue nil
    @conn.execute("DROP SEQUENCE #{SEQUENCE_2431.upcase}") rescue nil

    # Create a table whose model points at a *custom* sequence via
    # `self.sequence_name`. We let create_table create its default PK sequence
    # (`<TABLE>_SEQ`) — the bug is about the model-level `self.sequence_name`
    # declaration being ignored at INSERT time, not the create_table option.
    schema_define do
      create_table TABLE_2431, force: true do |t|
        t.string  :code
        t.string  :name
        t.integer :lock_version, default: 0, null: false
      end
    end

    # Custom sequence the model will use instead of the auto-derived one.
    @conn.execute("CREATE SEQUENCE #{SEQUENCE_2431.upcase} START WITH 1000 INCREMENT BY 1")

    Object.send(:remove_const, :Issue2431Category) if Object.const_defined?(:Issue2431Category)
    klass = Class.new(ActiveRecord::Base) do
      self.table_name    = TABLE_2431.to_s
      self.sequence_name = SEQUENCE_2431
    end
    Object.const_set(:Issue2431Category, klass)
  end

  after(:all) do
    Object.send(:remove_const, :Issue2431Category) if Object.const_defined?(:Issue2431Category)
    ActiveRecord::Base.clear_cache!
    @conn.execute("DROP TABLE #{TABLE_2431.to_s.upcase}") rescue nil
    @conn.execute("DROP SEQUENCE #{TABLE_2431.to_s.upcase}_SEQ") rescue nil
    @conn.execute("DROP SEQUENCE #{SEQUENCE_2431.upcase}") rescue nil
  end

  before(:each) { set_logger }
  after(:each)  { clear_logger }

  it "populates the in-memory record's id after create! when self.sequence_name is set" do
    record = Issue2431Category.create!(code: "1111", name: "Reproduction")

    # The core assertion from the bug report: on 7.1.0, this would be nil even
    # though the row landed in the DB with the sequence-fetched id.
    expect(record.id).not_to be_nil,
      "expected record.id to be populated after create!, but it was nil " \
      "(this is the 7.1.0 symptom from issue #2431)"
    expect(record.id).to be_a(Integer)
    expect(record.id).to be >= 1000  # sequence started at 1000

    # And the database actually has a row with that id (i.e. the id on the
    # object matches the id that was written).
    db_id = @conn.select_value(
      "SELECT id FROM #{TABLE_2431.to_s.upcase} WHERE code = '1111'"
    )
    expect(db_id.to_i).to eq(record.id)
  end

  it "binds the sequence-fetched id into the INSERT (no RETURNING ... INTO) " \
     "and emits a SELECT against the custom sequence" do
    Issue2431Category.create!(code: "2222", name: "SQL shape")

    debug_log = @logger.output(:debug)

    # The adapter must consult the *custom* sequence, not a default
    # ISSUE_2431_CATEGORIES_SEQ derived from the table name. This is the
    # "ignores self.sequence_name" half of the issue title. The adapter
    # quotes identifiers, so the actual log shape is
    # `"ISSUE_2431_CAT_SEQ".NEXTVAL` — allow an optional closing quote
    # between the sequence name and the dot.
    expect(debug_log).to match(/#{Regexp.escape(SEQUENCE_2431.upcase)}"?\.nextval/i),
      "expected a `#{SEQUENCE_2431.upcase}.nextval` fetch but did not find one " \
      "in the debug log (adapter may be ignoring self.sequence_name):\n#{debug_log}"

    insert_log = @logger.logged(:debug).find do |line|
      line.include?("INSERT INTO") && line.include?(TABLE_2431.to_s.upcase)
    end
    expect(insert_log).not_to be_nil, "INSERT statement was not logged"

    # oracle-enhanced's documented contract for the sequence-prefetched path
    # (mirrors the assertion in oracle_enhanced_adapter_spec.rb around the
    # `with a sequence-prefetched primary key` context): the ID is bound into
    # VALUES and RETURNING ... INTO is NOT emitted.
    expect(insert_log).to match(/INSERT INTO "#{TABLE_2431.to_s.upcase}".*"ID"/im)
    expect(insert_log).not_to match(/\bRETURNING\b\s+(?:"|INTO\b)/i)
  end
end
