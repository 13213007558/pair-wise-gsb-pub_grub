require 'test_helper'

module PubGrub
  class MultiPlatformPackageSourceTest < Minitest::Test
    def test_solves_multiple_platforms_in_one_joint_solution
      result = PubGrub.solve_for_platforms(%i[linux macos]) do |s|
        s.root deps: { 'app' => '1.0.0' }

        s.add 'app', '1.0.0', deps: { 'shared' => '1.0.0' }, platform_deps: {
          'linux-tool' => { requirement: '1.0.0', platforms: :linux },
          'macos-tool' => { requirement: '1.0.0', platforms: :macos }
        }
        s.add 'shared', '1.0.0'
        s.add 'linux-tool', '1.0.0', platforms: :linux
        s.add 'macos-tool', '1.0.0', platforms: :macos
      end

      assert_equal({
        'app' => Gem::Version.new('1.0.0'),
        'shared' => Gem::Version.new('1.0.0')
      }, result.common)
      assert_equal(
        { 'linux-tool' => Gem::Version.new('1.0.0') },
        result[:linux]
      )
      assert_equal(
        { 'macos-tool' => Gem::Version.new('1.0.0') },
        result[:macos]
      )
      assert_equal(%i[linux macos], result.platforms.keys)
    end

    def test_platform_specific_dependencies_keep_one_shared_version
      result = PubGrub.solve_for_platforms(%i[linux macos]) do |s|
        s.root deps: { 'app' => '1.0.0' }

        s.add 'app', '1.0.0', platform_deps: {
          'constrained' => [
            { requirement: '>= 1.0.0', platforms: :linux },
            { requirement: '~> 1.0', platforms: :macos }
          ]
        }
        s.add 'constrained', '2.0.0'
        s.add 'constrained', '1.5.0'
      end

      assert_equal(Gem::Version.new('1.5.0'), result.common.fetch('constrained'))
      assert_empty(result[:linux])
      assert_empty(result[:macos])
    end

    def test_failure_reports_conflicting_platform_conditions
      source = Proc.new do
        PubGrub::MultiPlatformPackageSource.new(%i[linux macos]) do |s|
          s.root deps: { 'shared' => '>= 0' }
          s.add 'shared', '1.0.0', platforms: :linux
          s.add 'shared', '2.0.0', platforms: :macos
        end
      end

      failure = assert_raises(SolveFailure) do
        VersionSolver.new(source: source.call).solve
      end

      assert_includes failure.explanation, 'platform linux'
      assert_includes failure.explanation, 'platform macos'
      assert_includes failure.explanation, 'shared 1.0.0 is not available on macos'
      assert_includes failure.explanation, 'shared 2.0.0 is not available on linux'
    end

    def test_adding_a_version_available_on_all_target_platforms_resolves_it
      source = PubGrub::MultiPlatformPackageSource.new(%i[linux macos]) do |s|
        s.root deps: { 'shared' => '>= 0' }
        s.add 'shared', '1.0.0', platforms: :linux
        s.add 'shared', '2.0.0', platforms: :macos
        s.add 'shared', '3.0.0'
      end

      result = VersionSolver.new(source: source).solve
      result = source.result_for(result)

      assert_equal({ 'shared' => Gem::Version.new('3.0.0') }, result.common)
      assert_empty(result[:linux])
      assert_empty(result[:macos])
    end

    def test_conditional_dependencies_only_apply_where_parent_is_required
      result = PubGrub.solve_for_platforms(%i[linux macos]) do |s|
        s.root macos: { 'mac-parent' => '1.0.0' }

        s.add 'mac-parent', '1.0.0', platform_deps: {
          'conditional-shared' => { requirement: '~> 1.0', platforms: :linux }
        }
        s.add 'conditional-shared', '2.0.0'
      end

      assert_empty(result.common)
      assert_empty(result[:linux])
      assert_equal(
        { 'mac-parent' => Gem::Version.new('1.0.0') },
        result[:macos]
      )
    end
  end
end
