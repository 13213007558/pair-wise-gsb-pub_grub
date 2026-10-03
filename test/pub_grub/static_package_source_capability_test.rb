require "test_helper"

module PubGrub
  class StaticPackageSourceCapabilityTest < Minitest::Test
    def test_capability_dependency_selects_a_real_provider_and_records_the_provision
      source = image_source do |s|
        s.add 'app', '1.0.0', deps: { 'image-reader' => '>= 1.0' }
        s.root deps: { 'app' => '1.0.0' }
      end

      result = VersionSolver.new(source: source).solve

      assert_solution source, result, {
        'app' => '1.0.0',
        'fast-image' => '1.0.0',
        'fast-native' => '1.0.0'
      }
      assert_equal Provision.new(
        capability: 'image-reader',
        capability_version: Gem::Version.new('1.0.0'),
        package: 'fast-image',
        version: Gem::Version.new('1.0.0')
      ), result.provisions.fetch('image-reader')
    end

    def test_capability_provider_backtracks_after_a_downstream_conflict
      source = image_source do |s|
        s.add 'app', '1.0.0', deps: {
          'image-reader' => '>= 1.0',
          'fast-native' => '2.0.0'
        }
        s.add 'fast-native', '2.0.0'
        s.root deps: { 'app' => '1.0.0' }
      end

      result = VersionSolver.new(source: source).solve

      assert_solution source, result, {
        'app' => '1.0.0',
        'fast-native' => '2.0.0',
        'safe-image' => '1.0.0',
        'safe-decoder' => '1.0.0'
      }
      assert_equal 'safe-image', result.provisions.fetch('image-reader').package
    end

    def test_capability_version_is_independent_from_package_version
      source = StaticPackageSource.new do |s|
        s.add 'fast-image', '2.0.0', deps: { 'fast-native' => '2.0.0' }
        s.add 'fast-native', '2.0.0'
        s.add 'safe-image', '3.0.0', deps: { 'safe-decoder' => '3.0.0' }
        s.add 'safe-decoder', '3.0.0'
        s.add 'app', '1.0.0', deps: { 'image-reader' => '>= 2.0' }
        s.provides 'image-reader', '1.0.0', by: 'fast-image', version: '2.0.0'
        s.provides 'image-reader', '2.0.0', by: 'safe-image', version: '3.0.0'
        s.root deps: { 'app' => '1.0.0' }
      end

      result = VersionSolver.new(source: source).solve

      assert_equal Gem::Version.new('3.0.0'), result.fetch('safe-image')
      assert_equal Gem::Version.new('2.0.0'), result.provisions.fetch('image-reader').capability_version
      assert_equal Gem::Version.new('3.0.0'), result.provisions.fetch('image-reader').version
    end

    def test_mutually_exclusive_implementations_cannot_coexist
      source = image_source do |s|
        s.root deps: { 'fast-image' => '1.0.0', 'safe-image' => '1.0.0' }
      end

      error = assert_raises SolveFailure do
        VersionSolver.new(source: source).solve
      end

      assert_includes error.explanation, 'fast-image 1.0.0 is mutually exclusive with safe-image 1.0.0'
    end

    def test_failure_lists_providers_excluded_by_downstream_conflicts
      source = image_source do |s|
        s.add 'app', '1.0.0', deps: {
          'image-reader' => '>= 1.0',
          'fast-native' => '2.0.0',
          'safe-decoder' => '2.0.0'
        }
        s.add 'fast-native', '2.0.0'
        s.add 'safe-decoder', '2.0.0'
        s.root deps: { 'app' => '1.0.0' }
      end

      error = assert_raises SolveFailure do
        VersionSolver.new(source: source).solve
      end

      explanation = error.explanation
      assert_includes explanation, 'excluded: fast-image, safe-image'
      assert_includes explanation, 'every version of fast-image depends on fast-native = 1.0.0'
      assert_includes explanation, 'every version of safe-image depends on safe-decoder = 1.0.0'
    end

    private

    def image_source
      StaticPackageSource.new do |s|
        s.add 'fast-image', '1.0.0', deps: { 'fast-native' => '1.0.0' }
        s.add 'fast-native', '1.0.0'
        s.add 'safe-image', '1.0.0', deps: { 'safe-decoder' => '1.0.0' }
        s.add 'safe-decoder', '1.0.0'
        s.provides 'image-reader', '1.0.0', by: 'fast-image', version: '1.0.0'
        s.provides 'image-reader', '1.0.0', by: 'safe-image', version: '1.0.0'
        yield s
      end
    end
  end
end
