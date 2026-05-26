# frozen_string_literal: true

# Repro for rsim/oracle-enhanced#2216
# Title: With column having CLOB/BLOB data type an empty value is always inserted in the table.
# URL:   https://github.com/rsim/oracle-enhanced/issues/2216
#
# Reporter's environment: oracle_enhanced 6.1.4, Ruby 2.6.8, Oracle 19c.
# Reporter uses fluent-plugin-sql (which writes via ActiveRecord) and observes
# that CLOB/BLOB columns end up empty in the DB even though a non-empty value
# was supplied. The reporter notes the bug affects both INSERT and UPDATE.
#
# Related: #1588 — `update_all` with a CLOB column emitted
# `SET col = empty_clob()` instead of the supplied value.
#
# Strategy: exercise the write paths a Rails-aware bulk loader would take —
# per-record `create!`, `update_all`, and `insert_all` — with non-empty
# CLOB/BLOB payloads of various sizes and assert the data round-trips.
#
# STATUS (run against Oracle XE 21c via local docker, master @ e8e1677c,
# Rails 8.2.0.alpha, ruby-oci8 @ d1daf45):
#   - create!     with CLOB/BLOB (large + small):  PASSES — round-trips
#   - update_all  with CLOB/BLOB:                  PASSES — #1588 appears fixed
#   - insert_all  with CLOB/BLOB:                  FAILS  — ORA-00904: "S"."ID": invalid identifier
#
# The originally-reported "empty value inserted" symptom does NOT reproduce
# on the per-record and update_all paths. However, `insert_all` (the Rails-7+
# bulk path most likely to be used by something like fluent-plugin-sql) blows
# up with an Oracle MERGE-syntax error before it ever gets to write LOBs.
# That's a separate-but-adjacent bug in the oracle_enhanced upsert/insert_all
# MERGE generation, not LOB handling.

require "spec_helper"

RSpec.describe "Issue #2216: CLOB/BLOB columns receive empty values on bulk/raw writes" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    schema_define do
      create_table :issue_2216_lobs, force: true do |t|
        t.string :name, limit: 50
        t.text   :clob_data
        t.binary :blob_data
      end
    end

    class ::Issue2216Lob < ActiveRecord::Base
      self.table_name = "issue_2216_lobs"
    end
  end

  after(:all) do
    @conn.drop_table :issue_2216_lobs, if_exists: true
    Object.send(:remove_const, "Issue2216Lob") if defined?(::Issue2216Lob)
    ActiveRecord::Base.clear_cache!
  end

  after(:each) do
    Issue2216Lob.delete_all
  end

  let(:clob_payload) { "lorem ipsum " * 500 } # ~6KB — exceeds VARCHAR2 inline limit
  let(:blob_payload) { ("\x00\x01\x02\xff".b * 1000).force_encoding(Encoding::ASCII_8BIT) }

  context "per-record create! (LOB streaming path)" do
    it "round-trips a large CLOB" do
      record = Issue2216Lob.create!(name: "c-large", clob_data: clob_payload)
      record.reload
      expect(record.clob_data).to eq(clob_payload)
      expect(record.clob_data).not_to be_empty
    end

    it "round-trips a large BLOB" do
      record = Issue2216Lob.create!(name: "b-large", blob_data: blob_payload)
      record.reload
      expect(record.blob_data.b).to eq(blob_payload)
      expect(record.blob_data).not_to be_empty
    end

    it "round-trips a short CLOB (fits inline)" do
      record = Issue2216Lob.create!(name: "c-small", clob_data: "hello clob")
      expect(record.reload.clob_data).to eq("hello clob")
    end
  end

  context "Model.update_all (related to #1588)" do
    it "persists non-empty CLOB via update_all" do
      record = Issue2216Lob.create!(name: "u-clob", clob_data: "initial")
      Issue2216Lob.where(id: record.id).update_all(clob_data: clob_payload)
      expect(record.reload.clob_data).to eq(clob_payload)
    end

    it "persists non-empty BLOB via update_all" do
      record = Issue2216Lob.create!(name: "u-blob", blob_data: "init".b)
      Issue2216Lob.where(id: record.id).update_all(blob_data: blob_payload)
      expect(record.reload.blob_data.b).to eq(blob_payload)
    end
  end

  context "Model.insert_all (Rails 6+ bulk insert path)" do
    it "persists non-empty CLOB via insert_all" do
      Issue2216Lob.insert_all([{ name: "i-clob", clob_data: clob_payload }])
      row = Issue2216Lob.find_by!(name: "i-clob")
      expect(row.clob_data).to eq(clob_payload)
    end

    it "persists non-empty BLOB via insert_all" do
      Issue2216Lob.insert_all([{ name: "i-blob", blob_data: blob_payload }])
      row = Issue2216Lob.find_by!(name: "i-blob")
      expect(row.blob_data.b).to eq(blob_payload)
    end
  end
end
