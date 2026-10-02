require "test_helper"

module PubGrub
  class FeaturesTest < Minitest::Test
    def test_features_requested_by_multiple_edges_are_united
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', features: ['tls'] } }
        s.add 'cli', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', features: ['compression'] } }
        s.add 'net', '1.0.0', features: {
          'tls' => [],
          'compression' => [],
        }

        s.root deps: { 'app' => '>= 1.0', 'cli' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      result = solver.solve

      assert_equal %w[compression tls], solver.features['net']
      assert_solution source, result, {
        'app' => '1.0.0',
        'cli' => '1.0.0',
        'net' => '1.0.0',
      }
    end

    def test_default_features_are_enabled_by_default
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => '>= 1.0' }
        s.add 'net', '1.0.0', features: {
          'default' => ['tls'],
          'tls' => [],
        }

        s.root deps: { 'app' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      solver.solve

      assert_equal %w[default tls], solver.features['net']
    end

    def test_default_features_can_be_disabled
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', default_features: false } }
        s.add 'net', '1.0.0', features: {
          'default' => ['tls'],
          'tls' => [],
        }

        s.root deps: { 'app' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      solver.solve

      assert_nil solver.features['net']
    end

    def test_default_features_merge_across_edges
      # The edge opting out of default features is decided after the
      # edge requesting them: it must not erase the merged request
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => '>= 1.0' }
        s.add 'cli', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', default_features: false } }
        s.add 'net', '1.0.0', features: {
          'default' => ['tls'],
          'tls' => [],
        }

        s.root deps: { 'app' => '>= 1.0', 'cli' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      solver.solve

      assert_equal %w[default tls], solver.features['net']
    end

    def test_default_features_merge_across_edges_in_reverse_order
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', default_features: false } }
        s.add 'cli', '1.0.0', deps: { 'net' => '>= 1.0' }
        s.add 'net', '1.0.0', features: {
          'default' => ['tls'],
          'tls' => [],
        }

        s.root deps: { 'app' => '>= 1.0', 'cli' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      solver.solve

      assert_equal %w[default tls], solver.features['net']
    end

    def test_feature_pulls_in_another_feature
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', features: ['tls'] } }
        s.add 'net', '1.0.0', features: {
          'tls' => ['compression'],
          'compression' => [],
        }

        s.root deps: { 'app' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      solver.solve

      assert_equal %w[compression tls], solver.features['net']
    end

    def test_feature_pulls_in_extra_package
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', features: ['tls'] } }
        s.add 'net', '1.0.0', features: {
          'tls' => [{ 'native-tls' => '>= 0.1' }],
        }
        s.add 'native-tls', '2.0.0'
        s.add 'native-tls', '1.0.0'

        s.root deps: { 'app' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      result = solver.solve

      assert_equal %w[tls], solver.features['net']
      assert_solution source, result, {
        'app' => '1.0.0',
        'net' => '1.0.0',
        'native-tls' => '2.0.0',
      }
    end

    def test_inactive_feature_does_not_pull_in_extra_package
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => '>= 1.0' }
        s.add 'net', '1.0.0', features: {
          'tls' => [{ 'native-tls' => '>= 0.1' }],
        }
        s.add 'native-tls', '1.0.0'

        s.root deps: { 'app' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      result = solver.solve

      assert_nil solver.features['net']
      assert_solution source, result, {
        'app' => '1.0.0',
        'net' => '1.0.0',
      }
    end

    def test_feature_dependency_requests_features_on_its_target
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', features: ['tls'] } }
        s.add 'net', '1.0.0', features: {
          'tls' => [{ package: 'native-tls', constraint: '>= 0.1', features: ['sslv3'], default_features: false }],
        }
        s.add 'native-tls', '1.0.0', features: {
          'default' => ['ssl'],
          'ssl' => [],
          'sslv3' => [],
        }

        s.root deps: { 'app' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      solver.solve

      assert_equal %w[tls], solver.features['net']
      assert_equal %w[sslv3], solver.features['native-tls']
    end

    def test_cyclic_features_terminate
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', features: ['a'] } }
        s.add 'net', '1.0.0', features: {
          'a' => ['b'],
          'b' => ['a'],
        }

        s.root deps: { 'app' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      solver.solve

      assert_equal %w[a b], solver.features['net']
    end

    def test_cyclic_feature_dependencies_across_packages_terminate
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', features: ['tls'] } }
        s.add 'net', '1.0.0', features: {
          'tls' => [{ 'helper' => { constraint: '>= 1.0', features: ['ext'] } }],
        }
        s.add 'helper', '1.0.0', features: {
          'ext' => [{ 'net' => { constraint: '>= 1.0', features: ['tls'] } }],
        }

        s.root deps: { 'app' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      result = solver.solve

      assert_equal %w[tls], solver.features['net']
      assert_equal %w[ext], solver.features['helper']
      assert_solution source, result, {
        'app' => '1.0.0',
        'net' => '1.0.0',
        'helper' => '1.0.0',
      }
    end

    def test_root_dependencies_may_request_features
      source = StaticPackageSource.new do |s|
        s.add 'net', '1.0.0', features: {
          'tls' => [],
        }

        s.root deps: { 'net' => { features: ['tls'] } }
      end

      solver = VersionSolver.new(source: source)
      solver.solve

      assert_equal %w[tls], solver.features['net']
    end

    def test_backtracking_leaves_no_residual_feature_activation
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', features: ['tls'] } }
        s.add 'other', '1.0.0'

        s.add 'net', '2.0.0', features: {
          'tls' => ['sslv3', { 'fragile' => '>= 2.0' }],
          'sslv3' => [],
        }
        s.add 'net', '1.0.0', features: {
          'tls' => [],
        }

        s.add 'fragile', '2.0.0', deps: { 'other' => '< 1.0' }

        s.root deps: { 'app' => '>= 1.0', 'other' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      result = solver.solve

      # net 2.0.0 was selected, then undone when its feature
      # dependency on fragile proved unsatisfiable
      assert_operator solver.solution.attempted_solutions, :>, 1

      assert_solution source, result, {
        'app' => '1.0.0',
        'other' => '1.0.0',
        'net' => '1.0.0',
      }

      # no activation state unique to the retracted net 2.0.0 path
      assert_equal %w[tls], solver.features['net']
      refute solver.features.key?('fragile')
    end

    def test_backtracking_restores_features_when_path_is_retaken
      # net 2.0.0 pulls fragile via its tls feature; fragile conflicts,
      # so the solver backtracks. app2 then requests net without tls,
      # and the final activation must reflect only the live edges.
      source = StaticPackageSource.new do |s|
        s.add 'app', '1.0.0', deps: { 'net' => { constraint: '>= 1.0', features: ['tls'] } }
        s.add 'other', '1.0.0'

        s.add 'net', '2.0.0', features: {
          'tls' => [{ 'fragile' => '>= 2.0' }],
        }
        s.add 'net', '1.0.0', features: {
          'tls' => [],
        }

        s.add 'fragile', '2.0.0', deps: { 'other' => '< 1.0' }

        s.root deps: { 'app' => '>= 1.0', 'other' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      result = solver.solve

      assert_solution source, result, {
        'app' => '1.0.0',
        'other' => '1.0.0',
        'net' => '1.0.0',
      }
      assert_equal %w[tls], solver.features['net']
    end

    def test_backtracking_unwinds_the_activating_decision
      # a 2.0.0 activates feature x on p, which pulls in d; d conflicts
      # with b. The only valid solution is a 1.0.0, which does not
      # activate x. The solver must learn that the activation (not the
      # mere presence of p) caused the conflict.
      source = StaticPackageSource.new do |s|
        s.add 'p', '1.0.0', features: {
          'x' => [{ 'd' => '>= 1.0' }],
        }
        s.add 'a', '2.0.0', deps: { 'p' => { constraint: '>= 1.0', features: ['x'] } }
        s.add 'a', '1.0.0', deps: { 'p' => '>= 1.0' }
        s.add 'b', '2.0.0'
        s.add 'd', '1.0.0', deps: { 'b' => '< 2.0' }

        s.root deps: { 'p' => '>= 1.0', 'a' => '>= 1.0', 'b' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      result = solver.solve

      assert_solution source, result, {
        'p' => '1.0.0',
        'a' => '1.0.0',
        'b' => '2.0.0',
      }

      # the x activation and its pulled-in dependency are gone
      assert_nil solver.features['p']
      refute result.key?('d')
    end

    def test_backtracking_to_before_activation_then_reattaching
      # After the activating edge is rolled back, taking the same path
      # again must re-activate the same features.
      source = StaticPackageSource.new do |s|
        s.add 'p', '1.0.0', features: {
          'x' => [{ 'd' => '>= 1.0' }],
        }
        s.add 'a', '2.0.0', deps: { 'p' => { constraint: '>= 1.0', features: ['x'] }, 'c' => '>= 1.0' }
        s.add 'a', '1.0.0', deps: { 'p' => { constraint: '>= 1.0', features: ['x'] } }
        s.add 'c', '2.0.0', deps: { 'd' => '< 1.0' }
        s.add 'c', '1.0.0'
        s.add 'd', '1.0.0'

        s.root deps: { 'p' => '>= 1.0', 'a' => '>= 1.0' }
      end

      solver = VersionSolver.new(source: source)
      result = solver.solve

      # c 2.0.0 conflicts with the d pulled in by x, so the solver
      # backtracks to c 1.0.0 while keeping the x activation
      assert_solution source, result, {
        'p' => '1.0.0',
        'a' => '2.0.0',
        'c' => '1.0.0',
        'd' => '1.0.0',
      }
      assert_equal %w[x], solver.features['p']
    end
  end
end
