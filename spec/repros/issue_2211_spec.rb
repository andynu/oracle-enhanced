# frozen_string_literal: true

# Repro for rsim/oracle-enhanced#2211 - "CLOB and BLOB datatype are not supported"
# URL: https://github.com/rsim/oracle-enhanced/issues/2211
# Duplicate-of/related: #2216 - "With column having CLOB/BLOB data type an empty
# value is always inserted in the table."
#
# Reporter context: using fluentd's fluent-plugin-sql with the oracle_enhanced
# adapter against Oracle 19c on adapter version 6.1.4 (Ruby 2.6.8). When the
# target table has CLOB/BLOB columns and the plugin maps fluentd record fields
# onto them, the rows are inserted but the CLOB/BLOB columns end up empty.
# No error is logged.
#
# fluent-plugin-sql ultimately calls `record_class.create!(mapped_attrs)` on
# an ActiveRecord model built dynamically against the target table. So the
# minimal reproduction is: define a model on a table with `t.text` (CLOB) and
# `t.binary` (BLOB) columns, `create!` with non-empty content for both, reload,
# and assert that the content survived the round trip.
#
# Result on master (HEAD e8e1677c, 2026-05-26):
#   ALL PASS - 5 examples, 0 failures
# Conclusion: cannot reproduce on master. CLOB/BLOB round-trip works end-to-end
# via ActiveRecord on a stock oracle_enhanced setup. The bug was either always
# in the fluent-plugin-sql layer (column-mapping / value coercion before
# reaching AR), or it was specific to oracle_enhanced 6.1.4 + Rails 6.x and has
# since been fixed in the LOB write path. The reporter never followed up with
# a non-fluentd reproduction; #2216 (the linked duplicate) was raised against
# the same plugin and also lacks a non-fluentd repro. Recommend closing #2211
# as "unable to reproduce, no minimal AR repro provided" unless someone shows
# the empty-write at the AR layer.

RSpec.describe "issue 2211: CLOB and BLOB datatype round-trip via ActiveRecord" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection

    schema_define do
      create_table :issue_2211_logs, force: true do |t|
        t.string  :miologid,       limit: 64
        t.string  :messageid,      limit: 64
        t.datetime :timestamputc
        t.text   :activityinput   # CLOB - per #2216 column_mapping
        t.text   :activityoutput  # CLOB
        t.binary :payload         # BLOB
      end
    end

    class ::Issue2211Log < ActiveRecord::Base
      self.table_name = "issue_2211_logs"
    end
  end

  after(:all) do
    @conn.drop_table :issue_2211_logs, if_exists: true
    Object.send(:remove_const, "Issue2211Log") if Object.const_defined?(:Issue2211Log)
    ActiveRecord::Base.clear_cache!
  end

  let(:clob_text)  { "x" * 10_000 } # well past VARCHAR2(4000) so it really is a CLOB write
  let(:blob_bytes) { (0..255).to_a.pack("C*") * 50 } # ~12.5KB of binary

  it "reports the columns as CLOB / BLOB at the SQL type level" do
    cols = Issue2211Log.columns.index_by(&:name)
    expect(cols["activityinput"].sql_type).to eq("CLOB")
    expect(cols["activityoutput"].sql_type).to eq("CLOB")
    expect(cols["payload"].sql_type).to eq("BLOB")
  end

  it "round-trips a CLOB value via create! + reload (the fluent-plugin-sql path)" do
    rec = Issue2211Log.create!(
      miologid:       "mio-1",
      messageid:      "msg-1",
      timestamputc:   Time.now.utc,
      activityinput:  clob_text,
      activityoutput: "shorter clob value"
    )
    rec.reload
    expect(rec.activityinput).to eq(clob_text)
    expect(rec.activityoutput).to eq("shorter clob value")
  end

  it "round-trips a BLOB value via create! + reload" do
    rec = Issue2211Log.create!(
      miologid:  "mio-blob",
      messageid: "msg-blob",
      payload:   blob_bytes
    )
    rec.reload
    expect(rec.payload.bytesize).to eq(blob_bytes.bytesize)
    expect(rec.payload).to eq(blob_bytes)
  end

  it "does NOT silently store an empty CLOB when given non-empty content" do
    rec = Issue2211Log.create!(activityinput: "non-empty")
    rec.reload
    expect(rec.activityinput).not_to be_nil
    expect(rec.activityinput).not_to eq("")
    expect(rec.activityinput).to eq("non-empty")
  end

  it "does NOT silently store an empty BLOB when given non-empty content" do
    rec = Issue2211Log.create!(payload: "\x00\x01\x02not-empty")
    rec.reload
    expect(rec.payload).not_to be_nil
    expect(rec.payload).not_to eq("")
    expect(rec.payload.b).to eq("\x00\x01\x02not-empty".b)
  end
end
