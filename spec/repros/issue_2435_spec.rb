# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2435
# "Rails 7 insert_all! not working"
#
# Reporter symptom: Calling `Model.insert_all!(records_slice)` against an
# Oracle Cloud Autonomous Database raises:
#
#   ORA-24374: define not done before fetch or execute and fetch
#
# Reporter env:
#   activerecord                              ~> 7.1
#   activerecord-oracle-enhanced-adapter      ~> 7.1
#   Ruby 3.4.1
#   Oracle Cloud Autonomous DB Warehouse
#
# ORA-24374 is an OCI client-side error meaning the driver was asked to fetch
# from a statement that has output variables it never bound. In adapter terms,
# that points at the `RETURNING ... INTO :returning_id` path being attached to
# a multi-row INSERT (where the bind list cannot line up with N rows worth of
# returned values).
#
# Status against current master (8.2.0.alpha, Oracle XE 21c via Docker, CRuby
# 4.0.1 + ruby-oci8): the exact `ORA-24374` does NOT reproduce — the adapter's
# `build_insert_sql` (see lib/active_record/connection_adapters/oracle_enhanced/
# database_statements.rb:232) emits Oracle's `INSERT ALL ... SELECT 1 FROM DUAL`
# form, which carries no `RETURNING ... INTO` bind and therefore cannot trip
# the OCI define-vs-fetch mismatch behind ORA-24374. The reporter is on the
# `~> 7.1` line, which predates that fix; the issue is plausibly already
# resolved on master for them.
#
# What still fails on master is the upstream "insert_all! not working" theme
# more generally: the call shapes a Rails user would most naturally write —
# `Model.insert_all!([{...}, {...}])` WITHOUT supplying primary-key values —
# raise on Oracle. This spec pins those two failure modes alongside the one
# documented working shape:
#
#   1. Explicit-ID rows, sequence-backed PK — PASSES. This is the
#      shape the existing suite covers (oracle_enhanced_adapter_spec.rb:358).
#   2. Auto-ID rows, sequence-backed PK — FAILS with
#      ActiveRecord::NotNullViolation (ORA-01400: cannot insert NULL into
#      "ID"). The adapter does not pre-fetch sequence values when expanding
#      the multi-row INSERT ALL.
#   3. Auto-ID rows, IDENTITY PK — FAILS with
#      ActiveRecord::RecordNotUnique (ORA-00001). Oracle evaluates an
#      IDENTITY column's underlying sequence ONCE per INSERT ALL statement
#      and reuses that value across every row, violating the PK on the
#      second row.
#
# Cases (2) and (3) match exactly the limitation called out in the existing
# `describe "insert_all!"` block's preamble — "callers must supply IDs in
# either schema. Auto-PK injection is tracked as follow-up." — so this spec
# serves as a regression pin for that follow-up: when the adapter learns to
# inject sequence/identity values per row, these two examples should flip
# from failing to passing without changes here.
require "spec_helper"

RSpec.describe "issue #2435 - Rails 7 insert_all! reproduction" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
  end

  describe "explicit IDs with a sequence-backed PK (documented supported case)" do
    before(:all) do
      schema_define do
        create_table :issue2435_explicit_items, force: true do |t|
          t.string :name
          t.integer :qty
        end
      end
      class ::Issue2435ExplicitItem < ActiveRecord::Base
      end
    end

    after(:all) do
      schema_define do
        drop_table :issue2435_explicit_items, if_exists: true
      end
      Object.send(:remove_const, "Issue2435ExplicitItem") if defined?(Issue2435ExplicitItem)
      ActiveRecord::Base.clear_cache!
    end

    after(:each) { Issue2435ExplicitItem.delete_all }

    it "inserts multiple rows without raising ORA-24374" do
      expect {
        Issue2435ExplicitItem.insert_all!([
          { id: 1, name: "alpha", qty: 1 },
          { id: 2, name: "beta",  qty: 2 },
          { id: 3, name: "gamma", qty: 3 },
        ])
      }.not_to raise_error

      expect(Issue2435ExplicitItem.order(:qty).pluck(:name)).to eq(%w[alpha beta gamma])
    end
  end

  describe "auto-generated IDs with a sequence-backed PK (reporter's likely call shape)" do
    before(:all) do
      schema_define do
        create_table :issue2435_seq_items, force: true do |t|
          t.string :name
          t.integer :qty
        end
      end
      class ::Issue2435SeqItem < ActiveRecord::Base
      end
    end

    after(:all) do
      schema_define do
        drop_table :issue2435_seq_items, if_exists: true
      end
      Object.send(:remove_const, "Issue2435SeqItem") if defined?(Issue2435SeqItem)
      ActiveRecord::Base.clear_cache!
    end

    after(:each) { Issue2435SeqItem.delete_all }

    it "inserts multiple rows without raising ORA-24374" do
      expect {
        Issue2435SeqItem.insert_all!([
          { name: "alpha", qty: 1 },
          { name: "beta",  qty: 2 },
          { name: "gamma", qty: 3 },
        ])
      }.not_to raise_error

      expect(Issue2435SeqItem.order(:qty).pluck(:name)).to eq(%w[alpha beta gamma])
    end
  end

  describe "auto-generated IDs with an IDENTITY PK (Oracle 12.1+)" do
    before(:all) do
      unless ActiveRecord::Base.lease_connection.supports_identity_columns?
        skip "IDENTITY columns are not supported in this Oracle version"
      end
      schema_define do
        create_table :issue2435_identity_items, force: true, identity: true do |t|
          t.string :name
          t.integer :qty
        end
      end
      class ::Issue2435IdentityItem < ActiveRecord::Base
      end
    end

    after(:all) do
      if defined?(Issue2435IdentityItem)
        schema_define do
          drop_table :issue2435_identity_items, if_exists: true
        end
        Object.send(:remove_const, "Issue2435IdentityItem")
        ActiveRecord::Base.clear_cache!
      end
    end

    after(:each) { Issue2435IdentityItem.delete_all if defined?(Issue2435IdentityItem) }

    it "inserts multiple rows without raising ORA-24374" do
      expect {
        Issue2435IdentityItem.insert_all!([
          { name: "alpha", qty: 1 },
          { name: "beta",  qty: 2 },
          { name: "gamma", qty: 3 },
        ])
      }.not_to raise_error

      expect(Issue2435IdentityItem.order(:qty).pluck(:name)).to eq(%w[alpha beta gamma])
    end
  end
end
