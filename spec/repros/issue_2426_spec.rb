# frozen_string_literal: true

# Reproduction spec for upstream issue rsim/oracle-enhanced#2426
# "Trigger based primary key sequence not returned when prefetch_primary_key? is false"
# https://github.com/rsim/oracle-enhanced/issues/2426
#
# CLAIM: After upgrading to v7.0.3 (changes from PR #2157), inserts into a
# table whose primary key is assigned by a BEFORE INSERT trigger (from a
# sequence) no longer return the trigger-generated id back to ActiveRecord
# when the model declares `self.prefetch_primary_key? = false`.
#
# The user's workaround was to patch `sql_for_insert` to also emit the
# `RETURNING <pk> INTO :returning_id` clause when `pk` is a String (the
# upstream version only appended RETURNING when pk was something other
# than `false`, `nil`, `Array`, or `String` — i.e., a Symbol).
#
# Setup:
#   - Sequence `i2426_seq` started at 1000.
#   - Table `i2426_customers` with `customer_id` NUMBER as the PK.
#   - BEFORE INSERT trigger populates `customer_id` from the sequence when
#     the incoming row has a NULL PK value.
#   - AR model:
#       self.primary_key = :customer_id
#       def self.prefetch_primary_key? = false
#     so AR will NOT prefetch a sequence value client-side and will let
#     the trigger assign the id server-side. The adapter must then return
#     the trigger-generated id (via `RETURNING ... INTO :returning_id`)
#     so AR can populate the model's `id` attribute after `create!`.
#
# STATUS: not-reproduced on current master at e8e1677c.
# `sql_for_insert` on master always emits the RETURNING clause when a PK
# can be inferred (whether passed as Symbol, String, or fetched from the
# schema cache), so the trigger-generated id flows back to AR and
# `record.id` is populated after `create!`. The user's report appears to
# have been against an intermediate state of the adapter; the current
# code path is correct.

require "spec_helper"

RSpec.describe "Issue #2426: trigger-based PK returned when prefetch_primary_key? is false" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    conn = ActiveRecord::Base.lease_connection

    # Clean up any leftovers from a prior run.
    conn.execute("DROP TABLE i2426_customers") rescue nil
    conn.execute("DROP SEQUENCE i2426_seq")    rescue nil

    conn.execute("CREATE SEQUENCE i2426_seq START WITH 1000 INCREMENT BY 1")
    conn.execute(<<~SQL)
      CREATE TABLE i2426_customers (
        customer_id NUMBER PRIMARY KEY,
        name        VARCHAR2(100)
      )
    SQL
    conn.execute(<<~SQL)
      CREATE OR REPLACE TRIGGER i2426_customers_bi
      BEFORE INSERT ON i2426_customers
      FOR EACH ROW
      BEGIN
        IF :NEW.customer_id IS NULL THEN
          SELECT i2426_seq.NEXTVAL INTO :NEW.customer_id FROM dual;
        END IF;
      END;
    SQL
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.execute("DROP TABLE i2426_customers") rescue nil
    conn.execute("DROP SEQUENCE i2426_seq")    rescue nil
  end

  let(:customer_class) do
    Class.new(ActiveRecord::Base) do
      self.table_name  = "i2426_customers"
      self.primary_key = :customer_id

      # Force the adapter into the code path the issue is about:
      # do NOT prefetch the PK on the Ruby side; let the trigger assign it
      # and depend on RETURNING to ship it back.
      def self.prefetch_primary_key?(_table_name = nil)
        false
      end
    end
  end

  it "returns the trigger-generated id from the INSERT (via RETURNING)" do
    record = customer_class.create!(name: "Acme")

    expect(record.customer_id).to be_present,
      "expected create! to populate customer_id from the BEFORE INSERT " \
      "trigger via RETURNING. Got nil, matching the issue's report: the " \
      "trigger-generated id was not returned to AR."
    expect(record.customer_id).to be >= 1000

    # And it should match what the database actually stored.
    stored_id = ActiveRecord::Base.lease_connection.select_value(
      "SELECT customer_id FROM i2426_customers WHERE name = 'Acme'"
    ).to_i
    expect(record.customer_id.to_i).to eq(stored_id)
  end

  it "returns distinct trigger-generated ids across successive inserts" do
    a = customer_class.create!(name: "A")
    b = customer_class.create!(name: "B")

    expect(a.customer_id).to be_present
    expect(b.customer_id).to be_present
    expect(a.customer_id).not_to eq(b.customer_id),
      "each insert should pick up a fresh sequence value from the trigger; " \
      "two records sharing an id would indicate the adapter is returning a " \
      "stale/default value rather than the trigger-assigned one."
  end

  it "still returns the id even when AR is told nothing about the PK source" do
    # No SQL bind for customer_id is supplied; only `name` is bound.
    # This is the exact shape that triggered the user's report.
    sql = customer_class.send(:sanitize_sql, ["INSERT INTO i2426_customers (name) VALUES (?)", "Direct"])
    conn = ActiveRecord::Base.lease_connection

    # exec_insert returns an ActiveRecord::Result whose rows include the
    # RETURNING values when the adapter appended `RETURNING ... INTO ...`.
    result = conn.exec_insert(sql, "INSERT", [], "customer_id")

    returned_id = result.rows.first&.first
    expect(returned_id).to be_present,
      "exec_insert with pk: 'customer_id' should append RETURNING and ship " \
      "back the trigger-generated id. A nil here matches the issue's claim."
    expect(returned_id.to_i).to be >= 1000
  end
end
