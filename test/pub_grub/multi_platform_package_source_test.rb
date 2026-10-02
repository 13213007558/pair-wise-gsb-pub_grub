require "test_helper"

module PubGrub
  class MultiPlatformPackageSourceTest < Minitest::Test
    def v(string)
      Gem::Version.new(string)
    end

    def test_separates_common_from_platform_only_packages
      source = MultiPlatformPackageSource.new(:linux, :macos) do |s|
        s.root linux: { "app" => "1.0.0" }, macos: { "app" => "1.0.0" }

        s.add "app", "1.0.0", deps: {
          "shared" => ">= 1.0",
          "linux_only" => s.on(:linux) { "2.0.0" },
          "mac_only"   => s.on(:macos) { "3.0.0" }
        }
        s.add "shared", "1.2.0"
        s.add "linux_only", "2.0.0", platforms: [:linux]
        s.add "mac_only", "3.0.0", platforms: [:macos]
      end

      solution = PubGrub.solve_for_platforms(source)

      assert_equal({ "app" => v("1.0.0"), "shared" => v("1.2.0") }, solution.common)
      assert_equal({ "linux_only" => v("2.0.0") }, solution.only_on[:linux])
      assert_equal({ "mac_only" => v("3.0.0") }, solution.only_on[:macos])

      assert_equal(
        { "app" => v("1.0.0"), "shared" => v("1.2.0"), "linux_only" => v("2.0.0") },
        solution.for_platform(:linux)
      )
      assert_equal(
        { "app" => v("1.0.0"), "shared" => v("1.2.0"), "mac_only" => v("3.0.0") },
        solution.for_platform(:macos)
      )
    end

    def test_platform_scoped_dependency_with_tagged_requirement
      source = MultiPlatformPackageSource.new(:linux, :macos) do |s|
        s.root linux: { "app" => "1.0.0" }, macos: { "app" => "1.0.0" }

        # Same PlatformDependency shape, but built without the block helper.
        s.add "app", "1.0.0", deps: {
          "kqueue" => MultiPlatformPackageSource::PlatformDependency.new("1.0.0", :macos)
        }
        s.add "kqueue", "1.0.0"
      end

      solution = PubGrub.solve_for_platforms(source)

      assert_equal({ "app" => v("1.0.0") }, solution.common)
      refute solution.only_on[:linux].key?("kqueue")
      assert_equal({ "kqueue" => v("1.0.0") }, solution.only_on[:macos])
    end

    def test_common_package_must_have_one_version_everywhere
      source = MultiPlatformPackageSource.new(:linux, :macos) do |s|
        s.root linux: { "app" => "1.0.0" }, macos: { "app" => "1.0.0" }
        s.add "app", "1.0.0", deps: { "shared" => ">= 1.0" }
        s.add "shared", "1.0.0", platforms: [:linux]
        s.add "shared", "2.0.0", platforms: [:macos]
      end

      error = assert_raises PubGrub::SolveFailure do
        PubGrub.solve_for_platforms(source)
      end

      message = error.explanation
      assert_includes message, "version solving has failed"
      assert_includes message, "`linux`"
      assert_includes message, "`macos`"
      assert_includes message, "is not a version shared by every platform"
    end

    def test_adding_a_compatible_version_turns_failure_into_success
      build = lambda do |include_compatible:|
        MultiPlatformPackageSource.new(:linux, :macos) do |s|
          s.root linux: { "app" => "1.0.0" }, macos: { "app" => "1.0.0" }
          s.add "app", "1.0.0", deps: { "shared" => ">= 1.0" }
          # Each platform has a usable version on its own, but the two sets do
          # not intersect, so there is no single shared lockfile version.
          s.add "shared", "1.0.0", platforms: [:linux]
          s.add "shared", "2.0.0", platforms: [:macos]
          # A version available on both platforms makes the joint solve work.
          s.add "shared", "1.5.0" if include_compatible
        end
      end

      assert_raises PubGrub::SolveFailure do
        PubGrub.solve_for_platforms(build.call(include_compatible: false))
      end

      solution = PubGrub.solve_for_platforms(build.call(include_compatible: true))

      assert_equal({ "app" => v("1.0.0"), "shared" => v("1.5.0") }, solution.common)
      assert_empty solution.only_on[:linux]
      assert_empty solution.only_on[:macos]
    end

    def test_version_availability_is_filtered_per_platform
      source = MultiPlatformPackageSource.new(:linux, :macos) do |s|
        s.root linux: { "app" => "1.0.0" }, macos: { "app" => "1.0.0" }
        s.add "app", "1.0.0", deps: {
          "native" => s.on(:linux) { ">= 1.0" }
        }
        s.add "native", "2.0.0", platforms: [:linux]
      end

      solution = PubGrub.solve_for_platforms(source)

      assert_equal({ "app" => v("1.0.0"), "native" => v("2.0.0") }, solution.for_platform(:linux))
      assert_equal({ "app" => v("1.0.0") }, solution.for_platform(:macos))
      assert_equal({ "app" => v("1.0.0") }, solution.common)
    end

    def test_three_platforms_share_one_version
      source = MultiPlatformPackageSource.new(:linux, :macos, :windows) do |s|
        s.root(
          linux: { "app" => "1.0.0" },
          macos: { "app" => "1.0.0" },
          windows: { "app" => "1.0.0" }
        )
        s.add "app", "1.0.0", deps: { "shared" => ">= 1.0" }
        s.add "shared", "1.0.0", platforms: [:linux]
        s.add "shared", "2.0.0", platforms: [:macos]
        s.add "shared", "3.0.0", platforms: [:windows]
        s.add "shared", "1.5.0", platforms: [:linux, :macos]
        s.add "shared", "4.0.0"
      end

      solution = PubGrub.solve_for_platforms(source)

      assert_equal v("4.0.0"), solution.common["shared"]
    end

    def test_unknown_platform_is_rejected
      error = assert_raises ArgumentError do
        MultiPlatformPackageSource.new(:linux) do |s|
          s.root macos: { "app" => "1.0.0" }
        end
      end

      assert_includes error.message, "unknown platform"
    end

    def test_requires_at_least_one_platform
      assert_raises ArgumentError do
        MultiPlatformPackageSource.new
      end
    end

    def test_conflicting_constraints_on_shared_catalog_mentions_platforms
      # Every version is available on both platforms, so each platform has a
      # standalone solution; the joint solve fails only because the two
      # platform-specific drivers pin the same shared package to incompatible
      # versions.
      source = MultiPlatformPackageSource.new(:linux, :macos) do |s|
        s.root linux: { "app" => "1.0.0" }, macos: { "app" => "1.0.0" }
        s.add "app", "1.0.0", deps: {
          "linux_driver" => s.on(:linux) { "1.0.0" },
          "mac_driver"   => s.on(:macos) { "1.0.0" }
        }
        s.add "linux_driver", "1.0.0", platforms: [:linux], deps: { "shared" => "~> 1.0" }
        s.add "mac_driver", "1.0.0", platforms: [:macos], deps: { "shared" => "~> 2.0" }
        s.add "shared", "1.0.0"
        s.add "shared", "2.0.0"
      end

      error = assert_raises PubGrub::SolveFailure do
        PubGrub.solve_for_platforms(source)
      end

      message = error.explanation
      assert_includes message, "version solving has failed"
      assert_includes message, "`linux`"
      assert_includes message, "`macos`"
    end
  end
end
