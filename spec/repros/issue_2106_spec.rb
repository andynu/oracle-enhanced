# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2106
# Title: question about database.yml and database configuration
# URL: https://github.com/rsim/oracle-enhanced/issues/2106
# Classification: not-applicable (support question, not a bug)
#
# Reporter asks: what is the difference between `database: xe` and
# `database: /xe` in database.yml? Suspects both use the listener's
# service name and wants confirmation.
#
# Answer (confirmed by this spec, executing against Oracle XE):
#
#   1. Both forms connect to the same service. SYS_CONTEXT
#      'SERVICE_NAME' returns identical values for both.
#   2. The adapter normalizes `database: xe` to `/xe` before building
#      the EZCONNECT URL — see oci_connection.rb around line 365:
#
#          database = "/#{database}" unless database.start_with?("/")
#          "//#{host}:#{port}#{database}"
#
#      This is the standard EZCONNECT form documented in sqlplus:
#
#          sqlplus user/pass@//host:port/service_name
#
#      The leading slash separates host:port from the service name
#      (EZCONNECT uses `:SID` for SIDs, not `/SID`), so both
#      `database: xe` and `database: /xe` are interpreted as a
#      service name — never as a SID.
#   3. The leading-slash form is now deprecated. Running the third
#      example below emits:
#
#          Setting `:database` to a value that starts with `/` is
#          deprecated and will raise in a future major version.
#          Use `database: "xe"` or `service_name: "xe"` instead.
#
#      So the modern guidance is: drop the slash, or use the explicit
#      `service_name:` key.
#
# This spec passes against Oracle XE; no fix needed in oracle-enhanced.

require "spec_helper"

RSpec.describe "Issue #2106: database.yml `xe` vs `/xe`" do
  after do
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "accepts `database: xe` (no leading slash) and connects" do
    params = CONNECTION_PARAMS.merge(database: DATABASE_NAME)
    ActiveRecord::Base.establish_connection(params)

    conn = ActiveRecord::Base.lease_connection
    expect(conn).to be_active
    expect(conn.select_value("SELECT 1 FROM dual")).to eq(1)
  end

  it "accepts `database: /xe` (with leading slash) and connects" do
    params = CONNECTION_PARAMS.merge(database: "/#{DATABASE_NAME}")
    ActiveRecord::ConnectionAdapters::OracleEnhanced.deprecator.silence do
      ActiveRecord::Base.establish_connection(params)
    end

    conn = ActiveRecord::Base.lease_connection
    expect(conn).to be_active
    expect(conn.select_value("SELECT 1 FROM dual")).to eq(1)
  end

  it "both forms reach the same Oracle service" do
    plain_service = nil
    slashed_service = nil

    ActiveRecord::Base.establish_connection(
      CONNECTION_PARAMS.merge(database: DATABASE_NAME)
    )
    plain_service = ActiveRecord::Base.lease_connection.select_value(
      "SELECT SYS_CONTEXT('USERENV', 'SERVICE_NAME') FROM dual"
    )
    ActiveRecord::Base.connection_handler.clear_all_connections!

    ActiveRecord::ConnectionAdapters::OracleEnhanced.deprecator.silence do
      ActiveRecord::Base.establish_connection(
        CONNECTION_PARAMS.merge(database: "/#{DATABASE_NAME}")
      )
    end
    slashed_service = ActiveRecord::Base.lease_connection.select_value(
      "SELECT SYS_CONTEXT('USERENV', 'SERVICE_NAME') FROM dual"
    )

    expect(plain_service).to eq(slashed_service)
  end
end
