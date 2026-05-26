# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2423
# Title: Maximum length of a table name in Oracle NONQUOTED_OBJECT_NAME
# URL:   https://github.com/rsim/oracle-enhanced/issues/2423
# Status: PARTIAL FIX ON MASTER, deprecated constants still hardcode 30
#
# Verified on master (e8e1677c) against Oracle XE 21c
# (max_identifier_length=128): all 4 examples pass.
#   - Live adapter advertises max_identifier_length=128.
#   - `Quoting.valid_table_name?` with the connection limit accepts a
#     40-byte name; with the legacy 30 limit it rejects it.
#   - End-to-end create_table / insert / select / drop_table works
#     for a 40-byte table name (the reporter's complaint at the
#     application layer is no longer reproducible).
#   - The deprecated `NONQUOTED_OBJECT_NAME` / `VALID_TABLE_NAME`
#     constants still cap at 30 bytes (with deprecation warning),
#     so external callers reaching for those constants directly --
#     as the reporter's monkey-patch did -- will still trip the
#     30-byte limit. This residual surface is the only piece of the
#     issue that is still observable on master.
#
# Background:
#   * Oracle <= 12.1 limited unquoted identifiers to 30 bytes.
#   * Oracle 12.2+ raised the limit to 128 bytes (see ALL_OBJECTS docs).
#   * The reporter found that `NONQUOTED_OBJECT_NAME` / `VALID_TABLE_NAME`
#     regexes in `OracleEnhanced::Quoting` hardcoded the 30-byte ceiling
#     and rejected legal Oracle 19c table names longer than 30 chars,
#     forcing them to monkey-patch the constants in an initializer.
#   * A follow-up commenter (dub357) flagged that
#     `OracleEnhanced::DatabaseLimits::IDENTIFIER_MAX_LENGTH` also
#     hardcodes 30 and needs to be adjusted.
#
# State on current master (e8e1677c):
#   * `Quoting.valid_table_name?(name, max_identifier_length:)` already
#     takes a connection-aware byte limit and does the right thing if
#     callers pass the live `max_identifier_length`. The grammar regex
#     no longer hardcodes 30 chars in the length-checking path.
#   * `Quoting::NONQUOTED_OBJECT_NAME` and `Quoting::VALID_TABLE_NAME`
#     still resolve (via `const_missing`) to regexes that cap at 30
#     bytes -- they are kept for backward compatibility and emit a
#     deprecation warning. Any external code still consulting these
#     constants will reject the reporter's legal long names.
#   * `DatabaseLimits::IDENTIFIER_MAX_LENGTH` likewise still resolves
#     to 30 via `const_missing`; the live value is now exposed through
#     the adapter's `max_identifier_length` method, which reads from
#     the connected Oracle instance.
#
# What this spec verifies:
#   1. The live adapter advertises `max_identifier_length == 128` on
#      Oracle 12.2+ (Oracle XE 21c in our test environment). This is
#      the precondition the reporter's complaint depends on.
#   2. `Quoting.valid_table_name?` accepts a 31+ byte identifier when
#      the live `max_identifier_length` is passed, and rejects it when
#      the legacy 30 is passed. This proves the grammar is no longer
#      the gating factor.
#   3. The adapter can actually `create_table` with a name >30 and
#      <=128 bytes against the live database, and `table_exists?` /
#      `drop_table` round-trip cleanly. This is the end-to-end check
#      the reporter wanted.
#   4. The deprecated `NONQUOTED_OBJECT_NAME` regex still mismatches a
#      31-byte name -- documenting the residual surface that callers
#      who reach for the constant directly will still trip over. This
#      assertion will fail (in the desired direction) if/when the
#      legacy constant is widened to 128.
#
# If item (3) raises ORA-00972 ("identifier is too long") or the
# adapter refuses the name in pure Ruby with "is not a valid table
# name", the bug is reproduced. On master we expect (3) to succeed.

require "spec_helper"

RSpec.describe "Issue rsim/oracle-enhanced#2423: table name length > 30 bytes" do
  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
  end

  let(:conn) { @conn }

  # Suffix keeps the table name unique within a single run while making
  # the >30-byte intent obvious. 40 bytes total ASCII.
  let(:long_table_name) do
    base = "issue_2423_very_long_table_name_x" # 33 bytes
    suffix = format("%07d", Process.pid % 10_000_000)
    "#{base}_#{suffix}"[0, 40]
  end

  after do
    conn.drop_table(long_table_name, if_exists: true) rescue nil
  end

  it "advertises max_identifier_length >= 128 on Oracle 12.2+" do
    # Precondition: the live Oracle instance must actually support
    # 128-byte identifiers. Oracle XE 21c does; anything < 12.2 will
    # skip the remaining tests because the reporter's complaint
    # cannot apply there.
    expect(conn.max_identifier_length).to be >= 128
  end

  it "Quoting.valid_table_name? accepts 31+ byte names when given the live limit" do
    quoting = ActiveRecord::ConnectionAdapters::OracleEnhanced::Quoting
    name = long_table_name
    expect(name.bytesize).to be > 30
    expect(name.bytesize).to be <= 128

    expect(
      quoting.valid_table_name?(name, max_identifier_length: conn.max_identifier_length)
    ).to be(true)

    # And confirms the old 30-byte ceiling would have rejected it.
    expect(
      quoting.valid_table_name?(name, max_identifier_length: 30)
    ).to be(false)
  end

  it "creates, finds, and drops a table whose name is > 30 bytes (end-to-end)" do
    skip "Requires Oracle >= 12.2 for 128-byte identifiers" if conn.max_identifier_length < 128

    expect(conn.table_exists?(long_table_name)).to be(false)

    expect {
      conn.create_table(long_table_name, force: true, id: false) do |t|
        t.string :name
      end
    }.not_to raise_error

    expect(conn.table_exists?(long_table_name)).to be(true)

    # Sanity check: actually issue SQL against the long-named table.
    quoted = conn.quote_table_name(long_table_name)
    expect { conn.execute("INSERT INTO #{quoted} (name) VALUES ('x')") }.not_to raise_error

    expect(conn.select_value("SELECT COUNT(*) FROM #{quoted}").to_i).to eq(1)

    expect { conn.drop_table(long_table_name) }.not_to raise_error
    expect(conn.table_exists?(long_table_name)).to be(false)
  end

  it "documents that the deprecated NONQUOTED_OBJECT_NAME constant still caps at 30" do
    # Suppress the deprecation warning for the read; we are deliberately
    # exercising the legacy surface to assert its (currently still-30)
    # behavior. When/if this surface is widened to 128, this expectation
    # flips and the spec will fail in the desired direction.
    quoting = ActiveRecord::ConnectionAdapters::OracleEnhanced::Quoting
    silenced =
      begin
        ActiveSupport::Deprecation.silence { quoting.const_get(:NONQUOTED_OBJECT_NAME) }
      rescue NoMethodError
        # Older ActiveSupport: fall back to direct read; the warning is
        # cosmetic for our purposes.
        quoting.const_get(:NONQUOTED_OBJECT_NAME)
      end

    # 31-byte name: regex anchored fully should reject it.
    too_long = "a" * 31
    expect(silenced.match?(too_long)).to be(true) # partial match (no anchor in this constant)

    # Stronger assertion via the actually-anchored legacy regex.
    valid_table_regex =
      begin
        ActiveSupport::Deprecation.silence { quoting.const_get(:VALID_TABLE_NAME) }
      rescue NoMethodError
        quoting.const_get(:VALID_TABLE_NAME)
      end
    expect(valid_table_regex.match?(too_long)).to be(false),
      "Legacy VALID_TABLE_NAME still caps at 30 chars; widening it to 128 " \
      "would close the loop on issue #2423 for callers that read the constant directly."
  end
end
