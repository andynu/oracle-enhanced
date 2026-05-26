# frozen_string_literal: true

# Reproduction for rsim/oracle-enhanced#2329
# "Support https://github.com/rails/rails/pull/44591"
#
# Upstream Rails PR title is "Simplify adapter construction; defer connect
# until first use" (not "Add support for #insert_all to retain timestamps" —
# the task-instruction blurb was wrong; the issue body and PR title agree).
# The reporter quoted commit deec3004d8d (rails/rails) introducing
# `@unconfigured_connection` as the dummy connection adapters hold prior to a
# real connect. Methods that walked `@raw_connection` directly during
# adapter construction blew up with:
#
#   NoMethodError: undefined method `database_version' for nil:NilClass
#   # ./lib/.../oracle_enhanced_adapter.rb:699:in `get_database_version'
#
# Original adapter source (issue era):
#
#   def get_database_version # :nodoc:
#     OracleEnhanced::Version.new(@raw_connection.database_version.join('.'))
#   end
#
# `arel_visitor` → `supports_fetch_first_n_rows_and_offset?` → `database_version`
# pulled `get_database_version` during `initialize`, before Rails 7.1 had a
# chance to call `connect`. The reporter's repro:
#
#   bundle exec rspec ./spec/active_record/connection_adapters/emulation/oracle_adapter_spec.rb:12
#
# Status against current master (8.2.0.alpha, Oracle XE 21c via Docker, CRuby
# 4.0.1 + ruby-oci8): NOT-APPLICABLE / RESOLVED. `get_database_version` now
# routes through `with_raw_connection { |conn| conn.database_version }`
# (oracle_enhanced_adapter.rb:1107), which lazily materializes the real
# connection via `verify!`/`connect`. `establish_connection` followed by
# `lease_connection` no longer raises a NoMethodError on `nil`. All four
# examples below PASS, including the emulation-alias call shape that was
# the reporter's failing repro line. The Rails 7.1 deferred-connection
# work that PR #44591 represents has been absorbed into the adapter.
#
# This spec pins that behavior. It exercises the same paths the reporter's
# stack trace walked — adapter construction, `arel_visitor`,
# `database_version` — without going through the OracleAdapter emulation
# alias (which is orthogonal to the bug and adds its own configuration noise).
# If a future refactor reintroduces a bare `@raw_connection.xxx` call on the
# pre-connect path, these examples will fail with the original NoMethodError
# signature.
require "spec_helper"

RSpec.describe "issue #2329 - Rails 7.1 deferred connection construction" do
  after(:each) do
    # Restore the default connection in case any example replaced it.
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
  end

  it "constructs an adapter without raising NoMethodError on nil @raw_connection" do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    expect { ActiveRecord::Base.lease_connection }.not_to raise_error
    expect(ActiveRecord::Base.lease_connection).not_to be_nil
  end

  it "answers database_version after deferred connect without manual #connect" do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    conn = ActiveRecord::Base.lease_connection
    expect { conn.database_version }.not_to raise_error
    expect(conn.database_version).not_to be_nil
  end

  it "resolves arel_visitor (the exact frame the original stack trace hit)" do
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS)
    conn = ActiveRecord::Base.lease_connection
    # arel_visitor was the entrypoint into supports_fetch_first_n_rows_and_offset?
    # which dereferenced @raw_connection before connect. The method is private
    # on Rails 7.1+, so reach it via __send__ — we want to assert the original
    # NoMethodError on nil does not resurface.
    expect { conn.__send__(:arel_visitor) }.not_to raise_error
    expect(conn.__send__(:arel_visitor)).not_to be_nil
  end

  it "supports the OracleAdapter emulation alias from issue body" do
    # Same shape as the original failing example:
    # spec/active_record/connection_adapters/emulation/oracle_adapter_spec.rb:12
    ActiveRecord::Base.establish_connection(CONNECTION_PARAMS.merge(adapter: "oracle"))
    expect(ActiveRecord::Base.lease_connection).not_to be_nil
    expect(ActiveRecord::Base.lease_connection)
      .to be_a(ActiveRecord::ConnectionAdapters::OracleAdapter)
  end
end
