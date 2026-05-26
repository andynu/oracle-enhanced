# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2769
# Title: Remove Connection#select after migrating spec call sites off the internal helper
# URL: https://github.com/rsim/oracle-enhanced/issues/2769
# Status: not-applicable
# Notes: This is a refactor/cleanup task, not a reproducible bug. There is no end-user
#   visible failure to reproduce. PR #2768 marks Connection#select as :nodoc: because the
#   library itself has zero callers (`grep` against lib/ returns nothing) — the helper is
#   reached only from spec/active_record/connection_adapters/oracle_enhanced/connection_spec.rb.
#   The work to remove the helper is gated on migrating those spec call sites to the
#   AR-public API (lease_connection.select_one / .select_all) or to raw cursor iteration for
#   the SYS-only V$SESSION lookup. This file documents the current state — call sites that
#   still need migration and the lib/ definitions slated for deletion — so a future
#   change set can flip the assertions when the cleanup lands.

require "spec_helper"

RSpec.describe "Issue #2769: Remove Connection#select" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:oci_connection_path)  { File.join(repo_root, "lib/active_record/connection_adapters/oracle_enhanced/oci_connection.rb") }
  let(:jdbc_connection_path) { File.join(repo_root, "lib/active_record/connection_adapters/oracle_enhanced/jdbc_connection.rb") }
  let(:spec_call_site_path)  { File.join(repo_root, "spec/active_record/connection_adapters/oracle_enhanced/connection_spec.rb") }

  it "the adapter loads against the running Oracle container (sanity check)" do
    # Confirms the repro spec actually exercises the live DB, per the task contract.
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    expect(ActiveRecord::Base.lease_connection.select_value("SELECT 1 FROM dual").to_i).to eq(1)
  end

  it "Connection#select still exists on OCIConnection (pre-removal state)" do
    src = File.read(oci_connection_path)
    expect(src).to match(/^\s*def select\(sql, name = nil, return_column_names = false\) # :nodoc:$/),
      "Expected OracleEnhanced::OCIConnection#select to still be defined; this assertion " \
      "flips when issue #2769 lands and the helper is deleted."
  end

  it "Connection#select and #select_no_retry still exist on JDBCConnection (pre-removal state)" do
    src = File.read(jdbc_connection_path)
    expect(src).to match(/^\s*def select\(sql, name = nil, return_column_names = false\) # :nodoc:$/)
    expect(src).to match(/^\s*def select_no_retry\(sql, name = nil, return_column_names = false\)/)
  end

  it "lib/ has zero callers of Connection#select (the only callers are in spec/)" do
    lib_dir = File.join(repo_root, "lib")
    offenders = Dir.glob(File.join(lib_dir, "**", "*.rb")).flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, idx|
        # Exclude the def lines themselves, and the AR-public helpers that share the prefix.
        next if line =~ /\bdef\s+select(_no_retry)?\b/
        next unless line =~ /(?<!_)\.select\(/
        next if line =~ /\.(select_all|select_one|select_value|select_rows|select_prepared|select_each)\(/
        "#{path}:#{idx + 1}: #{line.strip}"
      end
    end
    expect(offenders).to be_empty,
      "Expected zero lib/ callers of Connection#select per issue #2769 background; found:\n#{offenders.join("\n")}"
  end

  it "the spec migration backlog has the expected number of call sites in connection_spec" do
    # Per the issue body: 6 call sites in connection_spec.rb that need to move
    # to lease_connection.select_one / cursor iteration (for SYS-only V$SESSION).
    lines = File.readlines(spec_call_site_path)
    callers = lines.each_with_index.filter_map do |line, idx|
      next unless line =~ /(@conn|@sys_conn|\bconn)\.select\(/
      next if line =~ /\.(select_all|select_one|select_value|select_rows)\(/
      [idx + 1, line.strip]
    end

    # Snapshot of current state; when this drops to 0, the lib/ deletion can land.
    expect(callers.size).to eq(6),
      "Expected 6 Connection#select call sites in connection_spec (per issue #2769); " \
      "found #{callers.size}:\n" + callers.map { |ln, s| "  L#{ln}: #{s}" }.join("\n")
  end

  it "documents the removal work (pending until spec migration lands)" do
    pending "Issue #2769: delete Connection#select from oci_connection.rb and " \
            "jdbc_connection.rb, and Connection#select_no_retry from jdbc_connection.rb, " \
            "after migrating the 6 spec call sites in connection_spec.rb to " \
            "ActiveRecord::Base.lease_connection.select_one / cursor iteration."
    raise "not yet done"
  end
end
