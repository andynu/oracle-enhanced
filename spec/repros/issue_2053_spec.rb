# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2053
# Title:  "Customizing NLS_DATE_FORMAT needed due to legacy stored procedures"
# URL:    https://github.com/rsim/oracle-enhanced/issues/2053
# Reported against: Rails 6.0.3.3, oracle-enhanced 6.0.4, Oracle 12.1.0.2
#
# Summary of the report:
#   In oracle-enhanced 5.x and earlier, users could control the Oracle session's
#   NLS_DATE_FORMAT via `ENV['NLS_DATE_FORMAT']` (e.g. 'DD-MON-RR'). Some Rails
#   apps depend on this because they call legacy PL/SQL stored procedures that
#   assume a specific non-default NLS_DATE_FORMAT. Starting in 6.x the adapter
#   unconditionally forces `nls_date_format = 'YYYY-MM-DD HH24:MI:SS'` and
#   `nls_timestamp_format = 'YYYY-MM-DD HH24:MI:SS:FF6'` on every session via
#   `FIXED_NLS_PARAMETERS`. Any user setting (`ENV['NLS_DATE_FORMAT']`, or
#   `:nls_date_format` in database.yml) is overridden because FIXED is applied
#   AFTER the DEFAULT/ENV pass. See:
#   lib/active_record/connection_adapters/oracle_enhanced_adapter.rb#L1223-L1230
#
# This is a feature request (config knob) more than a strict bug. We assert the
# adapter's current contract:
#   - FIXED_NLS_PARAMETERS still hardcodes nls_date_format / nls_timestamp_format
#   - At session establish time, the live Oracle session reports those fixed
#     values regardless of ENV['NLS_DATE_FORMAT']
# and we `pending` the actual configurability ask, so the spec turns green
# (becomes a real failure to investigate) once the adapter is changed to honor
# user overrides.
#
# Expected (feature request): user-supplied NLS_DATE_FORMAT wins, or at least
# can be opted into.
# Actual (on master @ e8e1677c): user value is silently overridden by
# FIXED_NLS_PARAMETERS.

require "spec_helper"

RSpec.describe "Issue #2053: customizing NLS_DATE_FORMAT" do
  CUSTOM_NLS_DATE_FORMAT = "DD-MON-RR"

  def session_nls_date_format(conn)
    row = conn.select_one(
      "SELECT value FROM nls_session_parameters WHERE parameter = 'NLS_DATE_FORMAT'"
    )
    row["value"] || row[:value]
  end

  describe "FIXED_NLS_PARAMETERS still hardcodes nls_date_format" do
    it "lists nls_date_format among the unconditionally-fixed parameters" do
      fixed = ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter::FIXED_NLS_PARAMETERS
      expect(fixed).to have_key(:nls_date_format)
      expect(fixed[:nls_date_format]).to eq("YYYY-MM-DD HH24:MI:SS")
    end
  end

  describe "ENV['NLS_DATE_FORMAT'] override" do
    before(:each) do
      @original_env = ENV["NLS_DATE_FORMAT"]
      ENV["NLS_DATE_FORMAT"] = CUSTOM_NLS_DATE_FORMAT

      # Force a brand-new connection so the alter-session run picks up the env.
      ActiveRecord::Base.remove_connection
      ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
      @conn = ActiveRecord::Base.lease_connection
    end

    after(:each) do
      ENV["NLS_DATE_FORMAT"] = @original_env
      ActiveRecord::Base.remove_connection
      ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    end

    it "currently ignores ENV['NLS_DATE_FORMAT'] and applies the fixed YYYY-MM-DD format (documents the bug)" do
      observed = session_nls_date_format(@conn)
      # This is the bug: even though ENV['NLS_DATE_FORMAT'] is set, the session
      # ends up on the FIXED value.
      expect(observed).to eq("YYYY-MM-DD HH24:MI:SS")
      expect(observed).not_to eq(CUSTOM_NLS_DATE_FORMAT)
    end

    it "honors ENV['NLS_DATE_FORMAT'] on the live session (feature ask)" do
      pending "Feature ask: oracle-enhanced 6.x forces FIXED_NLS_PARAMETERS, overriding ENV['NLS_DATE_FORMAT']"
      observed = session_nls_date_format(@conn)
      expect(observed).to eq(CUSTOM_NLS_DATE_FORMAT)
    end
  end

  describe ":nls_date_format in connection config" do
    before(:each) do
      ActiveRecord::Base.remove_connection
      ActiveRecord::Base.establish_connection(
        CONNECTION_PARAMS.merge(nls_date_format: CUSTOM_NLS_DATE_FORMAT)
      )
      @conn = ActiveRecord::Base.lease_connection
    end

    after(:each) do
      ActiveRecord::Base.remove_connection
      ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    end

    it "honors :nls_date_format from database.yml / connection config (feature ask)" do
      pending "Feature ask: oracle-enhanced 6.x forces FIXED_NLS_PARAMETERS, overriding :nls_date_format config"
      observed = session_nls_date_format(@conn)
      expect(observed).to eq(CUSTOM_NLS_DATE_FORMAT)
    end
  end
end

# ---------------------------------------------------------------------------
# Reproduction status on master @ e8e1677c (Rails 8.2.0.alpha, Ruby 4.0.1,
# Oracle 21c XE):
#
#   $ bundle exec rspec spec/repros/issue_2053_spec.rb
#   Issue #2053: customizing NLS_DATE_FORMAT
#     FIXED_NLS_PARAMETERS still hardcodes nls_date_format
#       lists nls_date_format among the unconditionally-fixed parameters
#     :nls_date_format in connection config
#       honors :nls_date_format from database.yml / connection config (PENDING)
#     ENV['NLS_DATE_FORMAT'] override
#       honors ENV['NLS_DATE_FORMAT'] on the live session (PENDING)
#       currently ignores ENV['NLS_DATE_FORMAT'] and applies the fixed
#         YYYY-MM-DD format (documents the bug)
#   Finished in 0.17s -- 4 examples, 0 failures, 2 pending
#
#   Pending bodies confirm:
#     expected: "DD-MON-RR"
#          got: "YYYY-MM-DD HH24:MI:SS"
#
#   Conclusion: REPRODUCED on master. The session NLS_DATE_FORMAT is forced to
#   the FIXED value regardless of ENV['NLS_DATE_FORMAT'] or the :nls_date_format
#   key in the connection config. Issue #2053 is still live: this is a
#   configurability gap. Root cause: oracle_enhanced_adapter.rb#L1223-L1230
#   applies FIXED_NLS_PARAMETERS after the DEFAULT_NLS_PARAMETERS / ENV pass,
#   silently overriding both.
# ---------------------------------------------------------------------------
