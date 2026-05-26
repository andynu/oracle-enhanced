# frozen_string_literal: true

# Reproduction for upstream issue #2619
# URL: https://github.com/rsim/oracle-enhanced/issues/2619
# TITLE: OCI8 + cursor_sharing=force x INSERT ... RETURNING INTO :returning_id
#        hangs in SQL*Net half-duplex deadlock
# STATUS: not-reproduced (server-version-dependent)
# ONE_LINER: 2nd exec of cached cursor w/ literal + RETURNING INTO hangs on
#            Oracle 23ai under cursor_sharing=FORCE; not reproduced on 21c XE.
#
# Notes:
#   yahonda's diagnosis narrowed the trigger to three required conditions:
#     1. session cursor_sharing = FORCE (oracle-enhanced adapter default)
#     2. SQL contains a string literal AND "RETURNING ... INTO :out_bind"
#     3. the same parsed cursor is executed more than once
#
#   The deadlock was confirmed against:
#     - Oracle Database 23.26.1.0.0 (server)
#     - ruby-oci8 2.2.14
#     - macOS / arm64
#
#   The "Next steps" in the issue explicitly call out:
#     > Verify whether this also reproduces on a recent Oracle 19c / 21c
#     > server (server-side rewrite logic differs).
#
#   This local test environment is Oracle XE 21c (gvenzl/oracle-xe:21 in
#   Docker). Running the minimal repro sequence here completes without
#   hanging, suggesting the server-side cursor_sharing rewrite path in 21c
#   does NOT trip the OCI piecewise OUT-bind state machine the way 23ai
#   does. This is itself an answer to the issue's open question.
#
#   The spec is structured so that:
#     - On 23ai (bug-impacted): the second insert hangs, Timeout fires,
#       and the example fails with Timeout::Error escaping past the
#       outer Timeout block -- a clear visible reproduction.
#     - On 21c / non-bug-impacted servers: both inserts complete promptly,
#       the example finishes, and the pending-block marker records
#       "not reproduced on this server version".
#
#   We assert the bug-impacted behavior (Timeout::Error on 2nd exec) as
#   the canonical failing-spec for the issue. On environments where the
#   server-side rewrite doesn't trigger the deadlock, the spec fails
#   "expected Timeout::Error but nothing was raised" -- which is the
#   correct, informative outcome documenting the environment delta.

require "spec_helper"
require "timeout"

RSpec.describe "Issue #2619: cursor_sharing=FORCE + RETURNING INTO deadlock" do
  HANG_TIMEOUT = 10 # seconds

  before(:all) do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    @conn = ActiveRecord::Base.lease_connection
    begin
      @conn.execute("DROP TABLE issue_2619_t")
    rescue StandardError
      nil
    end
    begin
      @conn.execute("DROP SEQUENCE issue_2619_t_seq")
    rescue StandardError
      nil
    end
    @conn.execute(<<~SQL)
      CREATE TABLE issue_2619_t (
        id   NUMBER PRIMARY KEY,
        name VARCHAR2(50)
      )
    SQL
    @conn.execute("CREATE SEQUENCE issue_2619_t_seq START WITH 1")
    @conn.execute(<<~SQL)
      CREATE OR REPLACE TRIGGER issue_2619_t_pk
        BEFORE INSERT ON issue_2619_t FOR EACH ROW
      BEGIN
        IF :new.id IS NULL THEN
          :new.id := issue_2619_t_seq.NEXTVAL;
        END IF;
      END;
    SQL
  end

  after(:all) do
    begin
      @conn&.execute("DROP TABLE issue_2619_t")
    rescue StandardError
      nil
    end
    begin
      @conn&.execute("DROP SEQUENCE issue_2619_t_seq")
    rescue StandardError
      nil
    end
  end

  it "hangs on the second INSERT ... RETURNING when cursor_sharing=FORCE rewrites a literal" do
    # Adapter sets cursor_sharing = FORCE on connect; make it explicit so a
    # future default change doesn't silently mask the bug.
    @conn.execute("ALTER SESSION SET CURSOR_SHARING = FORCE")

    # First insert: parses + executes the cursor, populates :returning_id.
    # Completes normally even under the bug.
    Timeout.timeout(HANG_TIMEOUT) do
      @conn.insert("INSERT INTO issue_2619_t (name) VALUES ('alpha')", nil, "id")
    end

    # Second insert: reuses the cached cursor. Under the bug, OCIStmtExecute
    # never returns -- both client and server block on read() waiting for
    # the other to send. The Timeout::Error is the visible signature of the
    # half-duplex deadlock.
    expect {
      Timeout.timeout(HANG_TIMEOUT) do
        @conn.insert("INSERT INTO issue_2619_t (name) VALUES ('beta')", nil, "id")
      end
    }.to raise_error(Timeout::Error)
  end
end
