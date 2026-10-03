require "test_helper"

module PubGrub
  class CapabilityTest < Minitest::Test
    def v(version)
      Gem::Version.new(version)
    end

    def test_capability_version_is_distinct_per_provider
      fast = CapabilityVersion.new("2.0.0", "fast-image")
      mini = CapabilityVersion.new("2.0.0", "mini-image")

      # Numerically equal to plain versions ...
      assert_equal v("2.0.0"), fast
      assert_equal v("2.0.0"), mini
      assert fast > v("1.9.0")
      assert fast < v("2.0.1")

      # ... but each provider is a distinct, orderable version
      refute_equal fast, mini
      refute_equal fast.hash, mini.hash
      assert_equal [fast, mini], [mini, fast].sort
      assert_equal CapabilityVersion.new("2.0.0", "fast-image"), fast
      assert_equal "2.0.0 (provided by fast-image)", fast.to_s
    end

    def test_prefers_highest_capability_version
      source = StaticPackageSource.new do |s|
        s.root deps: { "image-reader" => ">= 2.0" }

        s.add "fast-image", "1.0.0", provides: { "image-reader" => "2.1.0" }
        s.add "mini-image", "1.0.0", provides: { "image-reader" => "2.0.0" }
      end

      solver = VersionSolver.new(source: source)
      result = solver.solve

      assert_equal CapabilityVersion.new("2.1.0", "fast-image"), result["image-reader"]
      assert_equal v("1.0.0"), result["fast-image"]
      refute result.key?("mini-image")

      report = solver.solution_report
      assert_equal({ "fast-image" => v("1.0.0") }, report[:packages])
      assert_equal(
        { "image-reader" => { version: v("2.1.0"), provider: "fast-image", provider_version: v("1.0.0") } },
        report[:capabilities]
      )
    end

    # The preferred implementation conflicts downstream, so the solver must
    # backtrack and provide the capability from the other implementation.
    def test_falls_back_to_other_provider_on_downstream_conflict
      source = StaticPackageSource.new do |s|
        s.root deps: { "image-reader" => ">= 2.0" }

        # Preferred provider (higher capability version), but its own
        # dependency cannot be satisfied.
        s.add "fast-image", "1.0.0", deps: { "fast-codec" => "~> 2.0" }, provides: { "image-reader" => "2.1.0" }
        s.add "fast-codec", "1.0.0"

        # Lower capability version, but resolvable.
        s.add "mini-image", "1.0.0", deps: { "mini-codec" => "~> 1.0" }, provides: { "image-reader" => "2.0.0" }
        s.add "mini-codec", "1.0.0"
      end

      solver = VersionSolver.new(source: source)
      result = solver.solve

      # The preferred provider was attempted first, then rejected
      assert_operator solver.solution.attempted_solutions, :>, 1

      assert_equal CapabilityVersion.new("2.0.0", "mini-image"), result["image-reader"]
      assert_equal v("1.0.0"), result["mini-image"]
      assert_equal v("1.0.0"), result["mini-codec"]
      refute result.key?("fast-image")
      refute result.key?("fast-codec")

      # The final solution lists the real packages plus the provision relation.
      # Note the capability version (2.0.0) is independent from the provider's
      # own version (1.0.0).
      report = solver.solution_report
      assert_equal(
        { "mini-image" => v("1.0.0"), "mini-codec" => v("1.0.0") },
        report[:packages]
      )
      assert_equal(
        { "image-reader" => { version: v("2.0.0"), provider: "mini-image", provider_version: v("1.0.0") } },
        report[:capabilities]
      )
    end

    # Two providers offering the same capability version: the solver tries
    # them in preference order and can still switch on conflict.
    def test_same_capability_version_from_two_providers
      source = StaticPackageSource.new do |s|
        s.root deps: { "image-reader" => "~> 2.0" }

        s.add "mini-image", "1.0.0", deps: { "mini-codec" => "~> 9.0" }, provides: { "image-reader" => "2.0.0" }
        s.add "mini-codec", "1.0.0"
        s.add "fast-image", "1.0.0", provides: { "image-reader" => "2.0.0" }
      end

      solver = VersionSolver.new(source: source)
      report = solver.solution_report

      assert_equal({ "fast-image" => v("1.0.0") }, report[:packages])
      assert_equal(
        { "image-reader" => { version: v("2.0.0"), provider: "fast-image", provider_version: v("1.0.0") } },
        report[:capabilities]
      )
    end

    def test_capability_dependency_from_non_root_package
      source = StaticPackageSource.new do |s|
        s.root deps: { "app" => "~> 1.0" }

        s.add "app", "1.0.0", deps: { "image-reader" => ">= 2.0" }
        s.add "fast-image", "1.0.0", provides: { "image-reader" => "2.1.0" }
        s.add "mini-image", "1.0.0", provides: { "image-reader" => "2.0.0" }
      end

      solver = VersionSolver.new(source: source)
      report = solver.solution_report

      assert_equal(
        { "app" => v("1.0.0"), "fast-image" => v("1.0.0") },
        report[:packages]
      )
      assert_equal "fast-image", report[:capabilities]["image-reader"][:provider]
    end

    # Implementations declared mutually exclusive cannot coexist: even though
    # fast-image offers the higher capability version, png-tools forces
    # mini-image, so the capability must be provided by mini-image.
    def test_mutually_exclusive_providers_cannot_coexist
      source = StaticPackageSource.new do |s|
        s.root deps: { "image-reader" => ">= 2.0", "png-tools" => "~> 1.0" }

        s.add "png-tools", "1.0.0", deps: { "mini-image" => "~> 1.0" }
        s.add "fast-image", "1.0.0", provides: { "image-reader" => "2.1.0" }
        s.add "mini-image", "1.0.0", provides: { "image-reader" => "2.0.0" }, conflicts: ["fast-image"]
      end

      solver = VersionSolver.new(source: source)
      report = solver.solution_report

      assert_equal(
        { "png-tools" => v("1.0.0"), "mini-image" => v("1.0.0") },
        report[:packages]
      )
      assert_equal(
        { "image-reader" => { version: v("2.0.0"), provider: "mini-image", provider_version: v("1.0.0") } },
        report[:capabilities]
      )
    end

    def test_conflict_also_blocks_direct_co_installation
      source = StaticPackageSource.new do |s|
        s.root deps: { "fast-image" => "~> 1.0", "mini-image" => "~> 1.0" }

        s.add "fast-image", "1.0.0", provides: { "image-reader" => "2.1.0" }
        s.add "mini-image", "1.0.0", provides: { "image-reader" => "2.0.0" }, conflicts: ["fast-image"]
      end

      solver = VersionSolver.new(source: source)

      ex = assert_raises PubGrub::SolveFailure do
        solver.solve
      end
      assert_equal <<~ERR.strip, ex.explanation.strip
        Because no versions satisfy mini-image > 1.0.0, < 2.A
          and mini-image 1.0.0 conflicts with fast-image,
          fast-image >= 0 is incompatible with mini-image >= 1.0.0, < 2.A.
        So, because root depends on fast-image ~> 1.0
          and root depends on mini-image ~> 1.0,
          version solving has failed.
      ERR
    end

    # No provider can satisfy the capability: the failure explanation shows
    # every provider that was ruled out, and why.
    def test_failure_lists_excluded_providers
      source = StaticPackageSource.new do |s|
        s.root deps: { "image-reader" => ">= 2.0" }

        s.add "fast-image", "1.0.0", deps: { "fast-codec" => "~> 2.0" }, provides: { "image-reader" => "2.1.0" }
        s.add "fast-codec", "1.0.0"
        s.add "mini-image", "1.0.0", deps: { "mini-codec" => "~> 9.0" }, provides: { "image-reader" => "2.0.0" }
        s.add "mini-codec", "1.0.0"
      end

      solver = VersionSolver.new(source: source)

      ex = assert_raises PubGrub::SolveFailure do
        solver.solve
      end
      assert_equal <<~ERR.strip, ex.explanation.strip
        Because image-reader < 2.1.0 (provided by fast-image) depends on mini-image = 1.0.0
          and every version of mini-image depends on mini-codec ~> 9.0,
          image-reader < 2.1.0 (provided by fast-image) requires mini-codec ~> 9.0.
        And because no versions satisfy mini-codec ~> 9.0
          and image-reader >= 2.1.0 (provided by fast-image) depends on fast-image = 1.0.0,
          fast-image = 1.0.0 is required.
        So, because every version of fast-image depends on fast-codec ~> 2.0
          and no versions satisfy fast-codec ~> 2.0,
          version solving has failed.
      ERR
    end

    def test_capability_with_no_providers
      source = StaticPackageSource.new do |s|
        s.root deps: { "image-reader" => ">= 2.0" }

        s.add "fast-image", "1.0.0"
      end

      solver = VersionSolver.new(source: source)

      ex = assert_raises PubGrub::SolveFailure do
        solver.solve
      end
      assert_equal <<~ERR.strip, ex.explanation.strip
        root depends on unknown package image-reader
      ERR
    end

    def test_capability_name_colliding_with_real_package_is_rejected
      error = assert_raises ArgumentError do
        StaticPackageSource.new do |s|
          s.root deps: {}
          s.add "image-reader", "1.0.0"
          s.add "fast-image", "1.0.0", provides: { "image-reader" => "2.0.0" }
        end
      end
      assert_match(/image-reader/, error.message)
    end
  end
end
