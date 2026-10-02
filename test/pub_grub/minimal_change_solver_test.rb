require "test_helper"

module PubGrub
  class MinimalChangeSolverTest < Minitest::Test
    def v(string)
      Gem::Version.new(string)
    end

    # spec: { name => { Gem::Version => { dep => requirement } } }
    def build_source(spec, root_deps)
      StaticPackageSource.new do |s|
        spec.each do |name, versions|
          versions.each do |version, deps|
            s.add name, version.to_s, deps: deps
          end
        end
        s.root deps: root_deps
      end
    end

    # Ground truth: enumerate every combination of versions, keep the
    # combinations satisfying all dependency constraints, and return the
    # minimal change cost. Only feasible for small instances.
    def brute_force_best_cost(spec, root_deps, locked, costs)
      names = spec.keys.sort
      version_lists = names.map { |name| spec[name].keys }
      combos = version_lists.inject([[]]) do |acc, versions|
        acc.product(versions.map { |version| [version] }).map { |a, b| a + b }
      end

      best = nil
      combos.each do |combo|
        assignment = Hash[names.zip(combo)]
        reachable = reachable_solution(assignment, spec, root_deps)
        next if reachable.nil?

        cost = MinimalChangeSolver.change_cost(reachable, locked: locked, costs: costs)
        best = cost if best.nil? || cost < best
      end
      best
    end

    # The set of packages reachable from the root under +assignment+, or
    # nil if any reached dependency constraint is violated.
    def reachable_solution(assignment, spec, root_deps)
      reachable = {}
      queue = []
      root_deps.each do |dep, requirement|
        return nil unless dependency_satisfied?(assignment, dep, requirement)

        queue << dep
      end

      until queue.empty?
        package = queue.shift
        next if reachable.key?(package)

        version = assignment[package]
        reachable[package] = version
        spec.fetch(package).fetch(version).each do |dep, requirement|
          return nil unless dependency_satisfied?(assignment, dep, requirement)

          queue << dep
        end
      end
      reachable
    end

    def dependency_satisfied?(assignment, dep, requirement)
      version = assignment[dep]
      !version.nil? && PubGrub::RubyGems.parse_range(requirement).include?(version)
    end

    def test_change_cost_pricing_rules
      solution = { 'a' => v('1.0.0'), 'b' => v('2.0.0'), 'd' => v('1.0.0') }
      locked = { 'a' => v('1.0.0'), 'b' => v('1.0.0'), 'c' => v('1.0.0') }
      costs = { 'b' => 5, 'c' => 3, 'd' => 2 }

      # a unchanged (0), b changed (5), c removed (3), d added (2)
      assert_equal 10, MinimalChangeSolver.change_cost(solution, locked: locked, costs: costs)

      # default cost is 1 per changed package
      assert_equal 3, MinimalChangeSolver.change_cost(solution, locked: locked)

      # identical solution and lockfile is free
      assert_equal 0, MinimalChangeSolver.change_cost(solution, locked: solution)
    end

    def test_negative_costs_are_rejected
      source = build_source({ 'a' => { v('1.0.0') => {} } }, { 'a' => '>= 1.0.0' })

      assert_raises(ArgumentError) do
        MinimalChangeSolver.new(source: source, costs: { 'a' => -1 })
      end
    end

    def test_keeps_locked_versions_when_nothing_forces_a_change
      spec = {
        'a' => { v('1.0.0') => {}, v('2.0.0') => {} },
      }
      source = build_source(spec, { 'a' => '>= 1.0.0' })

      result = MinimalChangeSolver.new(source: source, locked: { 'a' => v('1.0.0') }).solve

      assert_predicate result, :optimal?
      assert_equal :optimal, result.status
      assert_equal 0, result.cost
      assert_equal({ 'a' => v('1.0.0') }, result.solution)
    end

    def test_forced_upgrade_pays_exactly_one_change
      spec = {
        'a' => { v('1.0.0') => {}, v('2.0.0') => {} },
      }
      source = build_source(spec, { 'a' => '>= 2.0.0' })

      result = MinimalChangeSolver.new(source: source, locked: { 'a' => v('1.0.0') }).solve

      assert_predicate result, :optimal?
      assert_equal 1, result.cost
      assert_equal({ 'a' => v('2.0.0') }, result.solution)
    end

    # Keeping the locked version of 'a' is feasible, but forces 'b' off its
    # locked version at a cost of 10. Changing 'a' instead costs only 1, so
    # preferring old versions is not optimal here.
    def test_keeping_old_version_can_be_more_expensive
      spec = {
        'a' => {
          v('1.0.0') => { 'b' => '>= 2.0.0' },
          v('2.0.0') => { 'b' => '>= 1.0.0' },
        },
        'b' => { v('1.0.0') => {}, v('2.0.0') => {} },
      }
      root_deps = { 'a' => '>= 1.0.0' }
      locked = { 'a' => v('1.0.0'), 'b' => v('1.0.0') }
      costs = { 'b' => 10 }
      source = build_source(spec, root_deps)

      keep_old = { 'a' => v('1.0.0'), 'b' => v('2.0.0') }
      assert_equal 10, MinimalChangeSolver.change_cost(keep_old, locked: locked, costs: costs)

      result = MinimalChangeSolver.new(source: source, locked: locked, costs: costs).solve

      assert_predicate result, :optimal?
      assert_equal 1, result.cost
      assert_equal({ 'a' => v('2.0.0'), 'b' => v('1.0.0') }, result.solution)

      assert_equal 1, brute_force_best_cost(spec, root_deps, locked, costs)
    end

    def test_added_and_removed_packages_are_priced
      spec = {
        'r' => {
          v('1.0.0') => { 'x' => '>= 1.0.0' },
          v('2.0.0') => { 'y' => '>= 1.0.0' },
        },
        'x' => { v('1.0.0') => {} },
        'y' => { v('1.0.0') => {} },
      }
      source = build_source(spec, { 'r' => '>= 2.0.0' })
      locked = { 'r' => v('1.0.0'), 'x' => v('1.0.0') }

      result = MinimalChangeSolver.new(source: source, locked: locked).solve

      assert_predicate result, :optimal?
      # r changed (1), x removed (1), y added (1)
      assert_equal 3, result.cost
      assert_equal({ 'r' => v('2.0.0'), 'y' => v('1.0.0') }, result.solution)
    end

    def test_budget_exhaustion_returns_unproven_incumbent
      spec = {
        'a' => {
          v('1.0.0') => { 'b' => '>= 2.0.0' },
          v('2.0.0') => { 'b' => '>= 1.0.0' },
        },
        'b' => { v('1.0.0') => {}, v('2.0.0') => {} },
      }
      source = build_source(spec, { 'a' => '>= 1.0.0' })
      locked = { 'a' => v('1.0.0'), 'b' => v('1.0.0') }
      costs = { 'b' => 10 }

      limited = MinimalChangeSolver.new(source: source, locked: locked, costs: costs, max_nodes: 1).solve

      refute_predicate limited, :optimal?
      assert_equal :feasible, limited.status
      assert_equal 1, limited.nodes_explored
      # still a valid, usable solution, just not proven cheapest
      assert_equal({ 'a' => v('1.0.0'), 'b' => v('2.0.0') }, limited.solution)
      assert_equal 10, limited.cost

      proven = MinimalChangeSolver.new(source: source, locked: locked, costs: costs).solve
      assert_predicate proven, :optimal?
      assert_operator proven.cost, :<, limited.cost
    end

    def test_zero_budget_finds_no_solution
      spec = { 'a' => { v('1.0.0') => {} } }
      source = build_source(spec, { 'a' => '>= 1.0.0' })

      result = MinimalChangeSolver.new(source: source, max_nodes: 0).solve

      refute_predicate result, :optimal?
      assert_equal :feasible, result.status
      assert_nil result.solution
      assert_nil result.cost
    end

    def test_unsolvable_raises_solve_failure
      spec = { 'a' => { v('1.0.0') => {} } }
      source = build_source(spec, { 'a' => '>= 5.0.0' })

      assert_raises(SolveFailure) do
        MinimalChangeSolver.new(source: source, locked: { 'a' => v('1.0.0') }).solve
      end
    end

    def test_matches_brute_force_on_hand_built_instances
      instances = []

      # A diamond where the cheap path requires changing the root dep.
      instances << [
        {
          'a' => {
            v('1.0.0') => { 'l' => '>= 2.0.0', 'r' => '>= 2.0.0' },
            v('2.0.0') => {},
          },
          'l' => { v('1.0.0') => {}, v('2.0.0') => {} },
          'r' => { v('1.0.0') => {}, v('2.0.0') => {} },
        },
        { 'a' => '>= 1.0.0' },
        { 'a' => v('1.0.0'), 'l' => v('1.0.0'), 'r' => v('1.0.0') },
        { 'l' => 4, 'r' => 4, 'a' => 3 },
      ]

      # A newly required package forces a locked shared dependency off its
      # old version, and an unused locked package is dropped.
      instances << [
        {
          'new' => { v('1.0.0') => { 'shared' => '>= 2.0.0' } },
          'old' => { v('1.0.0') => { 'shared' => '< 2.0.0' } },
          'shared' => { v('1.0.0') => {}, v('2.0.0') => {} },
        },
        { 'new' => '>= 1.0.0' },
        { 'old' => v('1.0.0'), 'shared' => v('1.0.0') },
        { 'old' => 1, 'shared' => 5, 'new' => 2 },
      ]

      instances.each do |spec, root_deps, locked, costs|
        source = build_source(spec, root_deps)
        result = MinimalChangeSolver.new(source: source, locked: locked, costs: costs).solve
        expected = brute_force_best_cost(spec, root_deps, locked, costs)

        assert_predicate result, :optimal?
        assert_equal expected, result.cost
        assert_equal expected, MinimalChangeSolver.change_cost(result.solution, locked: locked, costs: costs)
      end
    end

    def test_matches_brute_force_on_random_instances
      rng = Random.new(20261002)

      25.times do
        names = (0...rng.rand(2..6)).map { |i| "pkg#{i}" }
        spec = {}
        names.each_with_index do |name, i|
          versions = {}
          (1..rng.rand(1..3)).each do |number|
            deps = {}
            names[0...i].sample(rng.rand(0..2), random: rng).each do |dep|
              target = spec[dep].keys.sample(random: rng)
              deps[dep] = ">= #{target}"
            end
            versions[v("#{number}.0.0")] = deps
          end
          spec[name] = versions
        end

        root_deps = { names.last => '>= 1.0.0' }
        locked = {}
        names.each do |name|
          locked[name] = spec[name].keys.sample(random: rng) if rng.rand >= 0.3
        end
        costs = {}
        names.each { |name| costs[name] = rng.rand(0..3) }

        source = build_source(spec, root_deps)
        result = MinimalChangeSolver.new(source: source, locked: locked, costs: costs).solve
        expected = brute_force_best_cost(spec, root_deps, locked, costs)

        assert_predicate result, :optimal?
        assert_equal expected, result.cost, "cost mismatch for #{spec.inspect}"
        assert_equal expected, MinimalChangeSolver.change_cost(result.solution, locked: locked, costs: costs)
      end
    end
  end
end
