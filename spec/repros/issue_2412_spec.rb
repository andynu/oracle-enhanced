# frozen_string_literal: true

# Reproduction spec for upstream issue rsim/oracle-enhanced#2412
# Title:  "Request to package a JRuby version w/o ruby-oci8 dependency"
# URL:    https://github.com/rsim/oracle-enhanced/issues/2412
#
# Issue summary:
#   Reporter notes that activerecord-oracle_enhanced-adapter 7.1.0 published
#   to RubyGems.org declares ruby-oci8 as a runtime dependency. JRuby users
#   cannot install the gem from RubyGems.org because ruby-oci8 is a CRuby-only
#   native gem (it requires Oracle Instant Client + OCI headers, builds against
#   MRI). They have to install via git checkout instead. The request is for the
#   maintainer to publish a separate `-java` platform gem to RubyGems.org that
#   omits the ruby-oci8 runtime dependency.
#
# Status: not-applicable for a runtime reproduction spec.
#
#   This is a *packaging / release process* feature request, not a behavioral
#   bug in the adapter code. It cannot be reproduced by exercising the loaded
#   gem from RSpec — the relevant artifact is whatever .gem files the
#   maintainer uploads to RubyGems.org, which lives outside this repo.
#
#   The gemspec in this repo already conditionally declares ruby-oci8 only
#   when running under MRI / TruffleRuby:
#
#     if RUBY_PLATFORM.include?("java")
#       s.platform = Gem::Platform.new("java")
#     else
#       s.add_runtime_dependency("ruby-oci8")
#     end
#
#   So the source is correct. What's missing is the release workflow step
#   that actually builds the gem under JRuby (or with platform="java" forced)
#   and pushes the resulting *-java.gem alongside the MRI gem. That's a CI/CD
#   change, not a code change, and not something RSpec can drive.
#
# What this spec does:
#   1. Pins the current state of the gemspec via a documentation assertion
#      (gemspec conditionally adds ruby-oci8 — passing today, will alert us
#      if someone regresses to an unconditional dependency).
#   2. Leaves a `pending` example describing the unresolved packaging gap
#      so the issue surfaces in the rspec output until a java-platform gem
#      is being published to RubyGems.org.
#
# Current observed behavior (on master, MRI ruby 3.4.x):
#   3 examples, 0 failures, 1 pending — the two gemspec-shape assertions
#   pass, confirming the source code is already structured to omit
#   ruby-oci8 on the java platform. The pending example documents the
#   release-pipeline gap.

require "spec_helper"

RSpec.describe "Issue #2412: JRuby packaging without ruby-oci8 dependency" do
  let(:gemspec_path) do
    File.expand_path("../../activerecord-oracle_enhanced-adapter.gemspec", __dir__)
  end

  let(:gemspec_source) { File.read(gemspec_path) }

  it "gemspec conditionally adds ruby-oci8 only for non-JRuby platforms" do
    # Pin the current shape of the gemspec. The fix for #2412 lives in the
    # release pipeline, not here, but if anyone reverts to an unconditional
    # `add_runtime_dependency("ruby-oci8")` they will break JRuby installation
    # all over again — this test will catch that regression.
    expect(gemspec_source).to match(/RUBY_PLATFORM\.include\?\("java"\)/)
    expect(gemspec_source).to match(/Gem::Platform\.new\("java"\)/)
    expect(gemspec_source).to match(/add_runtime_dependency\(\s*"ruby-oci8"\s*\)/)

    # Specifically: the ruby-oci8 dependency must live inside the `else`
    # branch of the platform check, not at top-level.
    java_block = gemspec_source[/if RUBY_PLATFORM\.include\?\("java"\).*?^  end/m]
    expect(java_block).not_to be_nil,
      "Expected gemspec to contain a `if RUBY_PLATFORM.include?(\"java\") ... end` block"
    expect(java_block).to include('add_runtime_dependency("ruby-oci8")')
    expect(java_block).to match(/else\s+s\.add_runtime_dependency\("ruby-oci8"\)/),
      "Expected ruby-oci8 dependency inside the else branch of the platform check"
  end

  it "loaded gem spec on this platform reflects the platform-conditional dependency" do
    # Cross-check: whatever gemspec Bundler resolved for this process should
    # match the platform we're running on.
    spec = Gem.loaded_specs["activerecord-oracle_enhanced-adapter"]

    if spec.nil?
      # Running from a source checkout via Bundler.setup — load the gemspec
      # directly from disk.
      spec = Gem::Specification.load(gemspec_path)
    end

    expect(spec).not_to be_nil

    oci8_dep = spec.runtime_dependencies.find { |d| d.name == "ruby-oci8" }

    if RUBY_PLATFORM.include?("java")
      expect(oci8_dep).to be_nil,
        "JRuby build should not declare ruby-oci8 as a runtime dependency"
    else
      expect(oci8_dep).not_to be_nil,
        "MRI build should declare ruby-oci8 as a runtime dependency"
    end
  end

  pending(
    "RubyGems.org publishes a -java platform gem for activerecord-oracle_enhanced-adapter " \
    "that omits the ruby-oci8 runtime dependency (issue #2412 — packaging/release-pipeline " \
    "work, not a source code fix; verify by inspecting " \
    "https://rubygems.org/gems/activerecord-oracle_enhanced-adapter for a `java` platform " \
    "release alongside the `ruby` platform release)"
  ) do
    # Intentionally no body — this is a reminder that the upstream release
    # workflow needs to push a -java gem. Not reproducible from RSpec.
    raise "packaging gap — see issue #2412"
  end
end
