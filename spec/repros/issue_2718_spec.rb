# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2718
# Title: Support DEFERRABLE on CHECK constraints (Oracle-specific extension)
# URL: https://github.com/rsim/oracle-enhanced/issues/2718
# Status: reproduced
# Notes: Demonstrates that `add_check_constraint` currently silently ignores
#   a `deferrable:` option on the Oracle adapter. The emitted DDL contains
#   no DEFERRABLE clause, the underlying all_constraints row shows
#   deferrable='NOT DEFERRABLE', and `check_constraints(table_name)` does
#   not surface a :deferrable key. The feature parity with FK / unique
#   constraint deferrable handling (added in #2594 / #2701) has not yet
#   been implemented for CHECK constraints.

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2718 - DEFERRABLE on CHECK constraints" do
  include SchemaSpecHelper

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
  end

  before(:each) do
    schema_define do
      create_table :test_issue_2718_products, force: true do |t|
        t.integer :price
      end
    end
  end

  after(:each) do
    schema_define do
      drop_table :test_issue_2718_products, if_exists: true
    end
    ActiveRecord::Base.clear_cache!
  end

  # Helper: fetch raw deferrable/deferred state from all_constraints.
  def fetch_deferrable_state(table_name, constraint_name)
    rows = @conn.select_all(<<~SQL.squish)
      SELECT deferrable, deferred
        FROM all_constraints
       WHERE owner = SYS_CONTEXT('userenv', 'current_schema')
         AND table_name = '#{table_name.upcase}'
         AND constraint_name = '#{constraint_name.upcase}'
    SQL
    rows.first
  end

  # ---------------------------------------------------------------------------
  # PASSING examples: document the current (broken/missing) behavior.
  # These pin down the bug so a future fix shows up as a behavior change.
  # ---------------------------------------------------------------------------

  it "currently ignores deferrable: :deferred on add_check_constraint (no DEFERRABLE clause emitted)" do
    schema_define do
      add_check_constraint :test_issue_2718_products, "price > 0",
                           name: "chk_2718_def", deferrable: :deferred
    end

    state = fetch_deferrable_state("test_issue_2718_products", "chk_2718_def")
    expect(state).not_to be_nil

    # BUG: Oracle records this CHECK constraint as NOT DEFERRABLE, even though
    # the caller asked for :deferred. When the feature is implemented this
    # should flip to "DEFERRABLE" / "DEFERRED" and this expectation will fail
    # -- which is the signal that the fix has landed.
    expect(state["deferrable"]).to eq("NOT DEFERRABLE")
    expect(state["deferred"]).to eq("IMMEDIATE")
  end

  it "currently ignores deferrable: :immediate on add_check_constraint" do
    schema_define do
      add_check_constraint :test_issue_2718_products, "price > 0",
                           name: "chk_2718_imm", deferrable: :immediate
    end

    state = fetch_deferrable_state("test_issue_2718_products", "chk_2718_imm")
    expect(state).not_to be_nil
    expect(state["deferrable"]).to eq("NOT DEFERRABLE")
  end

  it "check_constraints(table_name) reader does not surface :deferrable for CHECK constraints" do
    schema_define do
      add_check_constraint :test_issue_2718_products, "price > 0",
                           name: "chk_2718_reader", deferrable: :deferred
    end

    cc = @conn.check_constraints(:test_issue_2718_products)
                .detect { |c| c.name == "chk_2718_reader" }
    expect(cc).not_to be_nil

    # BUG: options[:deferrable] is missing from the reader output. The FK
    # and UC readers already populate it via extract_foreign_key_deferrable;
    # the CHECK reader does not.
    expect(cc.options.key?(:deferrable)).to eq(false)
  end

  it "structure_dump_check_constraints does not emit a DEFERRABLE clause" do
    schema_define do
      add_check_constraint :test_issue_2718_products, "price > 0",
                           name: "chk_2718_sd", deferrable: :deferred
    end

    dump_lines = @conn.structure_dump_check_constraints("test_issue_2718_products")
    line = dump_lines.find { |l| l.include?("CHK_2718_SD") }
    expect(line).not_to be_nil

    # BUG: the SQL structure dump should include "DEFERRABLE INITIALLY DEFERRED"
    # so that the dump round-trips, but currently it does not.
    expect(line).not_to match(/DEFERRABLE/i)
  end

  # ---------------------------------------------------------------------------
  # PENDING examples: document the desired API per the issue's acceptance
  # criteria. These will start passing once the feature is implemented.
  # ---------------------------------------------------------------------------

  xit "emits DEFERRABLE INITIALLY DEFERRED when deferrable: :deferred is passed" do
    schema_define do
      add_check_constraint :test_issue_2718_products, "price > 0",
                           name: "chk_2718_want_def", deferrable: :deferred
    end

    state = fetch_deferrable_state("test_issue_2718_products", "chk_2718_want_def")
    expect(state["deferrable"]).to eq("DEFERRABLE")
    expect(state["deferred"]).to eq("DEFERRED")
  end

  xit "emits DEFERRABLE INITIALLY IMMEDIATE when deferrable: :immediate is passed" do
    schema_define do
      add_check_constraint :test_issue_2718_products, "price > 0",
                           name: "chk_2718_want_imm", deferrable: :immediate
    end

    state = fetch_deferrable_state("test_issue_2718_products", "chk_2718_want_imm")
    expect(state["deferrable"]).to eq("DEFERRABLE")
    expect(state["deferred"]).to eq("IMMEDIATE")
  end

  xit "round-trips :deferrable through check_constraints(table_name) reader" do
    schema_define do
      add_check_constraint :test_issue_2718_products, "price > 0",
                           name: "chk_2718_want_rt", deferrable: :deferred
    end

    cc = @conn.check_constraints(:test_issue_2718_products)
                .detect { |c| c.name == "chk_2718_want_rt" }
    expect(cc.options[:deferrable]).to eq(:deferred)
  end

  xit "defaults to no DEFERRABLE clause and reports deferrable == false" do
    schema_define do
      add_check_constraint :test_issue_2718_products, "price > 0",
                           name: "chk_2718_want_default"
    end

    cc = @conn.check_constraints(:test_issue_2718_products)
                .detect { |c| c.name == "chk_2718_want_default" }
    expect(cc.options[:deferrable]).to eq(false).or be_nil
  end

  xit "raises ArgumentError for deferrable: true (matches FK / UC behaviour)" do
    expect {
      schema_define do
        add_check_constraint :test_issue_2718_products, "price > 0",
                             name: "chk_2718_want_invalid", deferrable: true
      end
    }.to raise_error(ArgumentError)
  end

  xit "SQL structure dump emits DEFERRABLE INITIALLY DEFERRED" do
    schema_define do
      add_check_constraint :test_issue_2718_products, "price > 0",
                           name: "chk_2718_want_sd", deferrable: :deferred
    end

    dump_lines = @conn.structure_dump_check_constraints("test_issue_2718_products")
    line = dump_lines.find { |l| l.include?("CHK_2718_WANT_SD") }
    expect(line).to match(/DEFERRABLE\s+INITIALLY\s+DEFERRED/i)
  end
end
