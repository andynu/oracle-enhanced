# frozen_string_literal: true

# Reproduction spec for upstream issue rsim/oracle-enhanced#2494
#
# Title:  JRuby 10 / JDK 21 compatibility issue with activerecord-jdbc-adapter
#         (WeakMap error)
# URL:    https://github.com/rsim/oracle-enhanced/issues/2494
# Status: blocked
# Reason: Requires JRuby 10 + JDK 21 + activerecord-jdbc-adapter ~> 72.0.
#         The local CRuby/OCI8 test environment cannot exercise the JDBC code
#         path where the WeakMap error originates. Reproducing this issue
#         requires a JRuby 10 runtime on OpenJDK 21, which is outside the
#         scope of this CRuby-driven spec suite.

require "spec_helper"

RSpec.describe "Issue #2494: JRuby 10 / JDK 21 WeakMap error" do
  it "is pending because the bug requires JRuby 10 + JDK 21" do
    # Honest assertion: we are NOT on JRuby, so we cannot trigger the
    # JRuby-internal WeakMap failure path from activerecord-jdbc-adapter.
    expect(RUBY_ENGINE).not_to eq("jruby"),
      "Expected to be running on CRuby; the JRuby 10 path is not reproducible here."

    pending "Requires JRuby 10 + OpenJDK 21 + activerecord-jdbc-adapter ~> 72.0 " \
            "to reproduce the WeakMap error on gem load."
    raise "not reproduced on CRuby"
  end
end
