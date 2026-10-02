require "test_helper"

module PubGrub
  class MinimalChangeSolverTest < Minitest::Test
    # Builds a StaticPackageSource from
    #   { name => { version_string => { dep_name => requirement } } }
    def build_source(spec, root_deps)
      StaticPackageSource.new do |s|
        spec.each do |name, versions|
          versions.each do |version, deps|
            s.add name, version, deps: deps
          end
        end
        s.root deps: root_deps
      end
    end

    def v(string)
      Gem::Version.new(string)
    end

    # Enumerates every combination of versions for every package, keeps
    # the combos whose reachable closure from the root satisfies all
    # dependencies, and returns the minimal change cost among them.
    # This is the independent oracle for the solver's optimality claim.
    def brute_force_best_cost(spec, root_deps, solver)
      normalized = spec.transform_values do |versions|
        versions.transform_keys { |version| v(version) }
      end
      names = normalized.keys
      version_lists = names.map { |name| normalized[name].keys }

      best = nil
      cartesian(version_lists).each do |combo|
        assignment = names.zip(combo).to_h
        solution = reachable_solution(normalized, root_deps, assignment)
        next unless solution

        cost = solver.cost_of(solution)
        best = cost if best.nil? || cost < best
      end
      best
    end

    def cartesian(lists)
      lists.reduce([[]]) do |acc, list|
        acc.flat_map { |combo| list.map { |value| combo + [value] } }
      end
    end

    # Computes the set of packages reachable from the root for a given
    # version assignment, or nil if some reached dependency is not
    # satisfied by the assignment.
    def reachable_solution(spec, root_deps, assignment)
      solution = {}
      queue = [:root]
      until queue.empty?
        package = queue.shift
        next if solution.key?(package)

        deps =
          if package == :root
            root_deps
          else
            normalized_deps = spec[package][assignment[package]]
            normalized_deps
          end
        deps.each do |dep, requirement|
          dep_version = assignment[dep]
          return nil unless dep_version
          return nil unless Gem::Requirement.new(requirement).satisfied_by?(dep_version)

          queue << dep
        end
        solution[package] = assignment[package] unless package == :root
      end
      solution
    end

    def assert_valid_solution(spec, root_deps, solution)
      decisions = solution.reject { |package, _| Package.root?(package) }
      normalized = spec.transform_values do |versions|
        versions.transform_keys { |version| v(version) }
      end
      reconstructed = reachable_solution(normalized, root_deps, decisions)
      refute_nil reconstructed, "expected #{decisions.inspect} to satisfy all dependencies"
      assert_equal reconstructed, decisions
    end

    def test_cost_model_pricing_rules
      source = build_source({ 'a' => { '1.0.0' => {} } }, { 'a' => '1.0.0' })
      solver = MinimalChangeSolver.new(
        source: source,
        lockfile: {
          'kept' => v('1.0.0'),
          'changed' => v('1.0.0'),
          'removed' => v('1.0.0'),
        },
        change_costs: { 'changed' => 3 },
        added_costs: { 'added' => 4 },
        removed_costs: { 'removed' => 5 },
      )

      solution = {
        Package.root => 0,
        'kept' => v('1.0.0'),    # same version as locked: 0
        'changed' => v('2.0.0'), # different version:     3
        'added' => v('1.0.0'),   # not in lockfile:       4
        # 'removed' is absent from the solution: 5
      }

      assert_equal 0 + 3 + 4 + 5, solver.cost_of(solution)
    end

    def test_costs_default_to_one
      source = build_source({ 'a' => { '1.0.0' => {} } }, { 'a' => '1.0.0' })
      solver = MinimalChangeSolver.new(
        source: source,
        lockfile: { 'a' => v('1.0.0'), 'gone' => v('1.0.0') },
      )

      solution = { 'a' => v('2.0.0'), 'new' => v('1.0.0') }
      # changed 'a' (1) + added 'new' (1) + removed 'gone' (1)
      assert_equal 3, solver.cost_of(solution)
    end

    def test_negative_costs_are_rejected
      source = build_source({ 'a' => { '1.0.0' => {} } }, { 'a' => '1.0.0' })

      assert_raises(ArgumentError) do
        MinimalChangeSolver.new(source: source, change_costs: { 'a' => -1 })
      end
      assert_raises(ArgumentError) do
        MinimalChangeSolver.new(source: source, added_costs: { 'a' => -0.5 })
      end
      assert_raises(ArgumentError) do
        MinimalChangeSolver.new(source: source, removed_costs: Hash.new(-2))
      end
    end

    # The key scenario: upgrading a direct dependency is cheap, but the
    # locked (old) version drags in an expensive new package. Preferring
    # the old version is NOT optimal here.
    def test_keeping_old_version_can_be_more_expensive
      spec = {
        'a' => {
          '1.0.0' => { 'c' => '>= 1.0.0' },
          '2.0.0' => {},
        },
        'c' => { '1.0.0' => {} },
      }
      root_deps = { 'a' => '>= 1.0.0' }
      source = build_source(spec, root_deps)
      lockfile = { 'a' => v('1.0.0') }

      # Greedy "prefer the locked version" solve keeps a 1.0.0 and is
      # forced to add the expensive c.
      greedy = VersionSolver.new(
        source: source,
        strategy: MinimalChangeSolver::LockfileStrategy.new(source, lockfile)
      ).solve
      assert_equal v('1.0.0'), greedy['a']
      assert_equal v('1.0.0'), greedy['c']

      solver = MinimalChangeSolver.new(
        source: source,
        lockfile: lockfile,
        change_costs: { 'a' => 1 },
        added_costs: { 'c' => 100 },
      )
      result = solver.solve

      assert_predicate result, :optimal?
      assert_equal 1, result.cost
      assert_equal v('2.0.0'), result.solution['a']
      refute result.solution.key?('c')

      # Independent oracle: enumerating all version combos agrees.
      assert_equal 1, brute_force_best_cost(spec, root_deps, solver)
    end

    def test_brute_force_verification_on_small_instances
      instances = []

      # Diamond with a shared dependency; the locked shared version is
      # excluded by the direct upgrade.
      instances << [
        {
          'a' => { '1.0.0' => { 'shared' => '>= 2.0.0' }, '2.0.0' => { 'shared' => '>= 2.0.0' } },
          'b' => { '1.0.0' => { 'shared' => '< 3.0.0' } },
          'shared' => { '1.0.0' => {}, '2.0.0' => {}, '3.0.0' => {} },
        },
        { 'a' => '>= 1.0.0', 'b' => '>= 1.0.0' },
        { 'a' => v('1.0.0'), 'b' => v('1.0.0'), 'shared' => v('1.0.0') },
        { change_costs: { 'a' => 2, 'b' => 2, 'shared' => 1 } },
      ]

      # A locked package that becomes unnecessary once 'a' is upgraded:
      # the optimal solution pays for the removal.
      instances << [
        {
          'a' => { '1.0.0' => { 'd' => '>= 1.0.0' }, '2.0.0' => {} },
          'd' => { '1.0.0' => {}, '2.0.0' => {} },
        },
        { 'a' => '>= 2.0.0' },
        { 'a' => v('1.0.0'), 'd' => v('1.0.0') },
        { change_costs: { 'a' => 5 }, removed_costs: { 'd' => 1 } },
      ]

      # Keeping everything old is cheapest here: the optimal cost is 0
      # even though newer versions exist.
      instances << [
        {
          'a' => { '1.0.0' => { 'b' => '>= 1.0.0' }, '2.0.0' => { 'b' => '>= 2.0.0' } },
          'b' => { '1.0.0' => {}, '2.0.0' => {} },
        },
        { 'a' => '>= 1.0.0' },
        { 'a' => v('1.0.0'), 'b' => v('1.0.0') },
        {},
      ]

      instances.each do |spec, root_deps, lockfile, costs|
        source = build_source(spec, root_deps)
        solver = MinimalChangeSolver.new(source: source, lockfile: lockfile, **costs)
        result = solver.solve

        assert_predicate result, :optimal?
        assert_valid_solution(spec, root_deps, result.solution)
        assert_equal result.cost, solver.cost_of(result.solution)
        assert_equal brute_force_best_cost(spec, root_deps, solver), result.cost,
          "solver cost mismatch for #{spec.inspect}"
      end
    end

    def test_budget_exhaustion_returns_feasible_unproven_solution
      spec = {
        'a' => {
          '1.0.0' => { 'c' => '>= 1.0.0' },
          '2.0.0' => {},
        },
        'c' => { '1.0.0' => {} },
      }
      root_deps = { 'a' => '>= 1.0.0' }
      source = build_source(spec, root_deps)
      lockfile = { 'a' => v('1.0.0') }
      costs = { change_costs: { 'a' => 1 }, added_costs: { 'c' => 100 } }

      # A single solve only produces the greedy (expensive) incumbent,
      # with no budget left to prove or improve it.
      limited = MinimalChangeSolver.new(source: source, lockfile: lockfile, max_solves: 1, **costs).solve
      assert_equal :feasible, limited.status
      refute_predicate limited, :optimal?
      refute_nil limited.solution
      assert_valid_solution(spec, root_deps, limited.solution)
      assert_equal 1, limited.solves

      # With enough budget the same instance is solved to proven
      # optimality, and the proven cost is no worse.
      full = MinimalChangeSolver.new(source: source, lockfile: lockfile, **costs).solve
      assert_equal :optimal, full.status
      assert_predicate full, :optimal?
      assert_operator limited.cost, :>=, full.cost
      assert_equal 1, full.cost
    end

    def test_zero_budget_returns_no_solution
      spec = { 'a' => { '1.0.0' => {} } }
      source = build_source(spec, { 'a' => '1.0.0' })

      result = MinimalChangeSolver.new(source: source, max_solves: 0).solve
      assert_equal :feasible, result.status
      refute_predicate result, :optimal?
      assert_nil result.solution
      assert_nil result.cost
    end

    def test_added_and_removed_packages_are_priced
      spec = {
        'a' => {
          '1.0.0' => {},
          '2.0.0' => { 'n' => '>= 1.0.0' },
        },
        'n' => { '1.0.0' => {} },
      }
      root_deps = { 'a' => '>= 2.0.0' }
      source = build_source(spec, root_deps)

      solver = MinimalChangeSolver.new(
        source: source,
        lockfile: { 'a' => v('1.0.0'), 'old' => v('9.9.9') },
        change_costs: { 'a' => 2 },
        removed_costs: { 'old' => 7 },
      )
      result = solver.solve

      assert_predicate result, :optimal?
      # changed 'a' (2) + added 'n' (default 1) + removed 'old' (7)
      assert_equal 2 + 1 + 7, result.cost
      assert_equal v('2.0.0'), result.solution['a']
      assert_equal v('1.0.0'), result.solution['n']
    end

    def test_unsatisfiable_dependencies_raise_solve_failure
      source = build_source(
        { 'a' => { '1.0.0' => {} } },
        { 'a' => '>= 2.0.0' },
      )

      assert_raises(SolveFailure) do
        MinimalChangeSolver.new(source: source).solve
      end
    end
  end
end
