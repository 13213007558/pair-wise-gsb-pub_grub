require_relative 'basic_package_source'
require_relative 'version_constraint'
require_relative 'version_solver'
require_relative 'strategy'
require_relative 'solve_failure'

module PubGrub
  # MinimalChangeSolver finds, among all solutions satisfying every
  # dependency, one whose total "change cost" against an existing
  # lockfile is minimal.
  #
  # This is useful for "conservative" updates: upgrading one direct
  # dependency should not needlessly churn every other locked version.
  #
  # ## Cost model
  #
  # Given a lockfile (a { package => version } mapping) and per-package,
  # non-negative costs, a candidate solution is priced as follows:
  #
  # * **kept**    -- package is in both the lockfile and the solution at
  #                  the SAME version: costs 0.
  # * **changed** -- package is in both, but at a DIFFERENT version:
  #                  costs +change_costs[package]+.
  # * **added**   -- package is in the solution but NOT in the lockfile
  #                  (newly introduced into the dependency graph): costs
  #                  +added_costs[package]+.
  # * **removed** -- package is in the lockfile but NOT in the solution
  #                  (no longer required): costs +removed_costs[package]+.
  #
  # Packages missing from a cost hash default to a cost of DEFAULT_COST.
  # All costs must be non-negative numbers; negative costs are rejected
  # with ArgumentError. The root package is never priced.
  #
  # ## Why not just "prefer old versions"?
  #
  # Preferring locked versions during solving (as LockfileStrategy does)
  # is only a heuristic: keeping an old version of one package can force
  # expensive changes (or additions) elsewhere, so the greedy solution is
  # not necessarily the cheapest. MinimalChangeSolver therefore runs a
  # branch-and-bound search over PubGrub solutions:
  #
  # * every node of the search is a set of assumptions (exact-version
  #   pins and version bans) solved by an ordinary VersionSolver,
  # * each found solution becomes the incumbent if it is the cheapest so
  #   far, and its remaining siblings are partitioned into child nodes,
  # * each node carries a lower bound on the cost of any solution beneath
  #   it; nodes whose lower bound is >= the incumbent are pruned.
  #
  # The search terminates when the queue of open nodes is empty, at which
  # point every solution has either been enumerated (and costs at least
  # the incumbent) or lies in a pruned subtree (and provably costs at
  # least the incumbent). That exhaustion is the optimality certificate.
  #
  # ## Budget and result states
  #
  # +max_solves+ bounds how many PubGrub solves (search nodes) may be
  # performed. If the budget runs out before the search space is
  # exhausted, the best solution found so far is returned with status
  # :feasible -- usable, but NOT proven optimal. The two outcomes are
  # distinguished by Result#status / Result#optimal?.
  class MinimalChangeSolver
    # Cost used for packages not listed in a cost hash.
    DEFAULT_COST = 1

    # The outcome of MinimalChangeSolver#solve.
    #
    # +status+ is exactly one of:
    #
    # [:optimal]  The search space was exhausted: every node was solved,
    #             proven infeasible, or pruned by its cost lower bound.
    #             It is PROVEN that no cheaper valid solution exists.
    # [:feasible] The solve budget (+max_solves+) ran out first.
    #             +solution+ is a valid set of versions, but a cheaper
    #             one may still exist. Optimality is NOT proven.
    class Result
      OPTIMAL = :optimal
      FEASIBLE = :feasible

      # { package => version } mapping, or nil if the budget was
      # exhausted before any solution was found.
      attr_reader :solution

      # Total change cost of +solution+ (nil when +solution+ is nil).
      attr_reader :cost

      # :optimal or :feasible
      attr_reader :status

      # How many PubGrub solves (search nodes) were performed.
      attr_reader :solves

      def initialize(solution:, cost:, status:, solves:)
        @solution = solution
        @cost = cost
        @status = status
        @solves = solves
      end

      # True only when it has been proven that no cheaper solution
      # exists.
      def optimal?
        @status == OPTIMAL
      end
    end

    # A Strategy which prefers the version recorded in the lockfile,
    # falling back to the default preference otherwise.
    #
    # Used to find a cheap incumbent early. Note this is only a
    # heuristic: the first solution it produces is not guaranteed to be
    # the cheapest.
    class LockfileStrategy < Strategy
      def initialize(source, lockfile)
        @lockfile = lockfile
        super(source)
      end

      private

      def most_preferred_version_of(package, range)
        old_version = @lockfile[package]
        if old_version && @source.versions_for(package, range).include?(old_version)
          old_version
        else
          super
        end
      end
    end

    # Internal: wraps a BasicPackageSource with node-local assumptions.
    #
    # * pins ({ package => version }) force a package to be present at
    #   an exact version; they are merged into the root dependencies.
    # * bans ({ package => VersionConstraint }) forbid specific versions
    #   WITHOUT forcing the package to be present; they filter the
    #   versions offered to the solver.
    class AssumptionSource < BasicPackageSource
      def initialize(source, pins:, bans:)
        @source = source
        @pins = pins
        @bans = bans
        # BasicPackageSource#incompatibilities_for references @packages
        # (normally provided by StaticPackageSource).
        @packages = {}
        super()
      end

      def all_versions_for(package)
        @source.all_versions_for(package)
      end

      def dependencies_for(package, version)
        @source.dependencies_for(package, version)
      end

      def root_dependencies
        deps = @source.root_dependencies
        return deps if @pins.empty?

        merged = deps.dup
        @pins.each do |package, version|
          pin = VersionConstraint.exact(package, version)
          parsed = merged.key?(package) && @source.parse_dependency(package, merged[package])
          merged[package] =
            if parsed
              parsed = VersionConstraint.new(package, range: parsed) unless parsed.is_a?(VersionConstraint)
              parsed.intersect(pin)
            else
              pin
            end
        end
        merged
      end

      def parse_dependency(package, dependency)
        case dependency
        when VersionConstraint, VersionRange, VersionUnion
          dependency
        else
          @source.parse_dependency(package, dependency)
        end
      end

      def versions_for(package, range = VersionRange.any)
        versions = @source.versions_for(package, range)
        ban = @bans[package]
        return versions unless ban

        versions.reject { |version| ban.range.include?(version) }
      end
    end

    attr_reader :source, :lockfile

    # @param source [BasicPackageSource] the package source to solve
    #   against
    # @param lockfile [Hash] { package => version } of the previous
    #   solution
    # @param change_costs [Hash] cost when a locked package ends up at a
    #   different version (default: DEFAULT_COST)
    # @param added_costs [Hash] cost when a package absent from the
    #   lockfile enters the solution (default: DEFAULT_COST)
    # @param removed_costs [Hash] cost when a locked package leaves the
    #   solution (default: DEFAULT_COST)
    # @param max_solves [Integer] budget of PubGrub solves (search
    #   nodes)
    def initialize(source:, lockfile: {}, change_costs: {}, added_costs: {}, removed_costs: {}, max_solves: 1000, logger: PubGrub.logger)
      @source = source
      @lockfile = lockfile.dup
      @change_costs = change_costs
      @added_costs = added_costs
      @removed_costs = removed_costs
      @max_solves = max_solves
      @logger = logger

      validate_costs!('change_costs', @change_costs)
      validate_costs!('added_costs', @added_costs)
      validate_costs!('removed_costs', @removed_costs)
    end

    # Total change cost of a solution ({ package => version }) against
    # the lockfile, using the pricing rules documented on the class.
    def cost_of(solution)
      cost = 0
      solution.each do |package, version|
        next if Package.root?(package)
        cost += version_cost(package, version)
      end
      lockfile.each_key do |package|
        cost += removed_cost(package) unless solution.key?(package)
      end
      cost
    end

    # Finds a solution of minimal total change cost.
    #
    # Raises SolveFailure if the dependencies are unsatisfiable at all.
    #
    # Returns a Result; check Result#status: :optimal means proven
    # minimal, :feasible means the budget ran out before optimality
    # could be proven.
    def solve
      # Priority queue of [lower_bound, sequence, pins, bans]
      nodes = []
      sequence = 0
      push_node = ->(pins, bans) do
        nodes << [lower_bound(pins, bans), sequence, pins, bans]
        sequence += 1
      end
      push_node.call({}, {})

      best_solution = nil
      best_cost = nil
      solves = 0
      first = true
      exhausted = true

      until nodes.empty?
        index = nodes.each_index.min_by { |i| [nodes[i][0], nodes[i][1]] }
        bound, _, pins, bans = nodes.delete_at(index)

        # Pruned: no solution beneath this node can beat the incumbent.
        next if best_cost && bound >= best_cost

        if solves >= @max_solves
          exhausted = false
          break
        end
        solves += 1

        solution =
          begin
            solve_node(pins, bans)
          rescue SolveFailure
            raise if first # the root node is infeasible: unsatisfiable input
            nil # this branch is infeasible
          end
        first = false
        next unless solution

        cost = cost_of(solution)
        if best_cost.nil? || cost < best_cost
          best_solution = solution
          best_cost = cost
        end

        branch(solution, pins, bans).each { |(child_pins, child_bans)| push_node.call(child_pins, child_bans) }
      end

      Result.new(
        solution: best_solution,
        cost: best_cost,
        status: exhausted ? Result::OPTIMAL : Result::FEASIBLE,
        solves: solves
      )
    end

    private

    def solve_node(pins, bans)
      source = AssumptionSource.new(@source, pins: pins, bans: bans)
      solver = VersionSolver.new(source: source, strategy: LockfileStrategy.new(source, @lockfile), logger: @logger)
      solver.solve
    end

    # Partitions the not-yet-enumerated solutions of the current node:
    # child i keeps the first i-1 decisions of +solution+ and forbids
    # the i-th, so every other solution of this node lands in exactly
    # one child.
    def branch(solution, pins, bans)
      children = []
      prefix = {}
      solution.each do |package, version|
        next if Package.root?(package)

        child_bans = bans.dup
        exact = VersionConstraint.exact(package, version)
        child_bans[package] = child_bans.key?(package) ? child_bans[package].union(exact) : exact
        children << [pins.merge(prefix), child_bans]

        prefix[package] = version
      end
      children
    end

    # Optimistic (never overestimating) cost bound for any solution
    # under the given assumptions.
    def lower_bound(pins, bans)
      bound = 0

      # Pinned packages are required at an exact version: exact cost.
      pins.each do |package, version|
        bound += version_cost(package, version)
      end

      lockfile.each do |package, old_version|
        next if pins.key?(package)

        banned = bans.key?(package) && bans[package].range.include?(old_version)
        root_constraint = root_constraints[package]
        allowed_by_root = root_constraint.nil? || root_constraint.range.include?(old_version)
        next if !banned && allowed_by_root

        # The old version is unusable. If the package is required by
        # the root it must change; otherwise it either changes or is
        # dropped.
        bound +=
          if root_constraint
            change_cost(package)
          else
            [change_cost(package), removed_cost(package)].min
          end
      end

      bound
    end

    def root_constraints
      @root_constraints ||= @source.root_dependencies.each_with_object({}) do |(package, dependency), constraints|
        parsed = @source.parse_dependency(package, dependency)
        next unless parsed
        parsed = VersionConstraint.new(package, range: parsed) unless parsed.is_a?(VersionConstraint)
        constraints[package] = parsed
      end
    end

    def version_cost(package, version)
      if lockfile.key?(package)
        lockfile[package] == version ? 0 : change_cost(package)
      else
        added_cost(package)
      end
    end

    def change_cost(package)
      @change_costs.fetch(package, DEFAULT_COST)
    end

    def added_cost(package)
      @added_costs.fetch(package, DEFAULT_COST)
    end

    def removed_cost(package)
      @removed_costs.fetch(package, DEFAULT_COST)
    end

    def validate_costs!(name, costs)
      costs.each do |package, cost|
        unless cost.is_a?(Numeric) && cost >= 0
          raise ArgumentError, "#{name}[#{package.inspect}] must be a non-negative number, got #{cost.inspect}"
        end
      end
      default = costs.default
      if default && !(default.is_a?(Numeric) && default >= 0)
        raise ArgumentError, "#{name} default must be a non-negative number, got #{default.inspect}"
      end
    end
  end
end
