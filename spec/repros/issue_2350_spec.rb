# frozen_string_literal: true
#
# Issue: rsim/oracle-enhanced#2350
# Title: Installation of >=v7.0.1 fails with JRuby
# URL: https://github.com/rsim/oracle-enhanced/issues/2350
# Status: cannot reproduce in CRuby environment; constraint verified
# Notes:
#   The bug is a packaging/release issue, not a source bug. As of commit
#   e5d99974 (first shipped in v7.0.1) the gemspec switched to declaring
#   `ruby-oci8` as a runtime dependency. The gemspec already guards that
#   dependency with `if RUBY_PLATFORM.include?("java")`, picking the
#   `java` platform variant for JRuby and adding the `ruby-oci8` dep for
#   CRuby:
#
#     if RUBY_PLATFORM.include?("java")
#       s.platform = Gem::Platform.new("java")
#     else
#       s.add_runtime_dependency("ruby-oci8")
#     end
#
#   Source-wise that's correct. The problem is that the maintainer only
#   pushes the CRuby-platform build to rubygems.org -- no java-platform
#   variant is published. Bundler on JRuby therefore picks up the CRuby
#   gem, sees `ruby-oci8` as a hard runtime dependency, and fails to
#   build that gem's C extension under JRuby. See
#   https://rubygems.org/gems/activerecord-oracle_enhanced-adapter/versions
#   -- every release is "ruby" platform, none are "java".
#
#   This thread of comments confirms the diagnosis: davue (2023-12-27)
#   and rammpeter (2025-07-13) both reproduce the failure with the
#   published gem and confirm that installing from the git source (which
#   evaluates the gemspec at install time on the user's JRuby) works fine.
#   rammpeter notes the issue is still present in v8.0.0 / on the
#   release80 branch when consumed via rubygems.org.
#
#   This spec cannot reproduce the JRuby gem-install failure from a CRuby
#   process: we have no JRuby on this test host, and even if we did, the
#   failure is in `gem install` (Bundler resolving the published spec),
#   not in any code we can exercise via RSpec. Instead we:
#
#     1. Mark a `pending` example documenting the JRuby reproduction
#        recipe so future readers can run it by hand.
#     2. Assert the load-bearing structural invariants in the current
#        gemspec that determine whether a fixed release CAN be produced:
#        the java-platform guard, the conditional ruby-oci8 dependency,
#        and that ruby-oci8 is NOT an unconditional runtime dep. If any
#        of those regress, the JRuby path will be broken regardless of
#        which platform variant is uploaded.

require "spec_helper"

RSpec.describe "Issue #2350: JRuby install fails because no java-platform gem is published" do
  let(:gemspec_path) do
    File.expand_path("../../../activerecord-oracle_enhanced-adapter.gemspec", __FILE__)
  end

  let(:gemspec_source) { File.read(gemspec_path) }

  let(:gemspec) do
    # Evaluate in the gemspec's own directory so the `File.read("../VERSION")`
    # call resolves correctly.
    Dir.chdir(File.dirname(gemspec_path)) do
      Gem::Specification.load(gemspec_path)
    end
  end

  it "guards the ruby-oci8 dependency on RUBY_PLATFORM (java vs C)" do
    # The structural fix in commit e5d99974 -- if this guard goes away,
    # JRuby breakage returns even for users who consume the gem from git.
    expect(gemspec_source).to match(/if\s+RUBY_PLATFORM\.include\?\(["']java["']\)/)
    expect(gemspec_source).to include(%(s.platform = Gem::Platform.new("java")))
    expect(gemspec_source).to include(%(s.add_runtime_dependency("ruby-oci8")))
  end

  it "does not list ruby-oci8 as an unconditional runtime dependency on CRuby" do
    # On a CRuby host (this test environment), the conditional adds
    # ruby-oci8. That's expected and correct. What we're guarding against
    # is a regression where ruby-oci8 leaks into the java-platform spec.
    if RUBY_PLATFORM.include?("java")
      dep_names = gemspec.runtime_dependencies.map(&:name)
      expect(dep_names).not_to include("ruby-oci8"),
        "ruby-oci8 must not be a runtime dep on the java-platform gem; " \
        "that is exactly what issue #2350 reports."
      expect(gemspec.platform.to_s).to eq("java")
    else
      dep_names = gemspec.runtime_dependencies.map(&:name)
      expect(dep_names).to include("ruby-oci8")
      expect(gemspec.platform.to_s).to eq("ruby")
    end
  end

  it "always declares activerecord and ruby-plsql as runtime deps regardless of platform" do
    dep_names = gemspec.runtime_dependencies.map(&:name)
    expect(dep_names).to include("activerecord")
    expect(dep_names).to include("ruby-plsql")
  end

  it "JRuby gem-install failure cannot be reproduced from CRuby RSpec" do
    skip <<~MSG
      Issue #2350 manifests during `bundle install` under JRuby when the
      resolver picks up the rubygems.org-published CRuby-platform gem,
      which declares `ruby-oci8` as a runtime dependency. ruby-oci8 has
      no JRuby build, so its C extension compile step fails.

      To reproduce by hand on a host with JRuby + rbenv:

        cd $(mktemp --directory)
        printf 'jruby-9.4.3.0\\n' > .ruby-version
        rbenv install --skip-existing
        printf 'source "https://rubygems.org"\\n' \\
               'gem "activerecord-oracle_enhanced-adapter", "8.0.0"\\n' > Gemfile
        bundle install
        # => Installing ruby-oci8 2.2.14 with native extensions
        # => Gem::Ext::BuildError: ERROR: Failed to build gem native extension.

      Fix path: publish a java-platform variant of the gem to rubygems.org
      (the gemspec already supports it; only the release workflow needs to
      build + push both variants). Workaround for affected users: pull the
      gem from git (`gem "...", github: "rsim/oracle-enhanced"`).
    MSG
  end
end
