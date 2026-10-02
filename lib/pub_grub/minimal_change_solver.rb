require_relative 'basic_package_source'
require_relative 'version_solver'
require_relative 'solve_failure'

module PubGrub
  # A solving mode which finds a solution minimizing the total cost of
  # changes relative to a previous lockfile, instead of just any solution.
  #
  # ## Cost model
  #
  # Every package has a non-negative change cost, given by +costs+ and
  # defaulting to DEFAULT_COST. Given the +locked+ mapping of previously
  # selected versions, the cost of a solution is the sum over all packages
  # (present in the solution, the lockfile, or both) of:
  #
  # * 0 if the package keeps its locked version
  # * cost(package) if the package is locked but selected at a different version
  # * cost(package) if the package is newly added (selected, but not locked)
  # * cost(package) if the package is removed (locked, but not selected)
  #
  # Locked versions are compared to selected versions with ==, so they
  # should be the same objects the package source returns.
  #
  # ## Search and optimality
  #
  # Preferring locked versions is a heuristic, not a guarantee: keeping an
  # old version of one package can force expensive changes elsewhere. This
  # solver therefore performs a branch-and-bound search over version
  # assignments, using PubGrub to complete each partial assignment and the
  # cost of the already-pinned packages as an admissible lower bound. A
  # result is only reported as optimal once every node which could
  # conceivably hold a strictly cheaper solution has been explored or
  # pruned by that bound.
  #
  # ## Budget
  #
  # +max_nodes+ caps how many PubGrub solves (search nodes) may be
  # performed. If the cap stops the search before optimality is proven, the
  # best solution found so far is returned with Result#optimal? == false
  # (Result#status == :feasible).
  class MinimalChangeSolver
    DEFAULT_COST = 1

    # The outcome of a MinimalChangeSolver run.
    #
    # There are two distinct kinds of result:
    #
    # * status :optimal (optimal? == true): the search completed and proved
    #   that no cheaper solution exists.
    # * status :feasible (optimal? == false): the node budget ran out first,
    #   so this is merely the cheapest solution found so far. A cheaper one
    #   may still exist.
    class Result
      # Hash of {package => version}. Unlike VersionSolver#solve, the root
      # package is not included. May be nil if the budget was exhausted
      # before any solution was found.
      attr_reader :solution

      # Total change cost of #solution. nil when #solution is nil.
      attr_reader :cost

      # How many PubGrub solves (search nodes) were performed.
      attr_reader :nodes_explored

      def initialize(solution:, cost:, optimal:, nodes_explored:)
        @solution = solution
        @cost = cost
        @optimal = optimal
        @nodes_explored = nodes_explored
      end

      # True only when the search proved that no cheaper solution exists.
      def optimal?
        @optimal
      end

      # :optimal when optimality was proven, :feasible otherwise.
      def status
        optimal? ? :optimal : :feasible
      end
    end

    # Wraps a package source so that pinned packages offer exactly one
    # version, forcing VersionSolver to select it.
    class PinnedSource < BasicPackageSource
      def initialize(source, pins)
        @source = source
        @pins = pins

        super()

        # BasicPackageSource#incompatibilities_for expects the concrete
        # source to define @packages; mirror it from the wrapped source.
        if @source.instance_variable_defined?(:@packages)
          @packages = @source.instance_variable_get(:@packages)
        end
      end

      def all_versions_for(package)
        if @pins.key?(package)
          [@pins[package]]
        else
          @source.all_versions_for(package)
        end
      end

      def dependencies_for(package, version)
        @source.dependencies_for(package, version)
      end

      def parse_dependency(package, dependency)
        @source.parse_dependency(package, dependency)
      end

      def root_dependencies
        @source.root_dependencies
      end
    end

    # The total change cost of +solution+ relative to +locked+, following
    # the cost model described on MinimalChangeSolver.
    def self.change_cost(solution, locked:, costs: {})
      packages = solution.keys | locked.keys
      packages.sum(0) do |package|
        next 0 if Package.root?(package)

        if solution[package] == locked[package]
          0
        else
          costs.fetch(package, DEFAULT_COST)
        end
      end
    end

    def initialize(source:, locked: {}, costs: {}, max_nodes: nil, logger: PubGrub.logger)
      @source = source
      @locked = locked
      @costs = costs
      @max_nodes = max_nodes
      @logger = logger

      @costs.each do |package, cost|
        if cost.nil? || cost < 0
          raise ArgumentError, "change cost for #{package} must be non-negative, got #{cost.inspect}"
        end
      end
    end

    # Returns a Result. Raises SolveFailure if no solution exists at all.
    def solve
      @nodes_explored = 0
      @budget_exhausted = false
      @best_solution = nil
      @best_cost = Float::INFINITY
      @root_failure = nil

      search({})

      raise @root_failure if @best_solution.nil? && @root_failure

      Result.new(
        solution: @best_solution,
        cost: @best_solution ? @best_cost : nil,
        optimal: !@budget_exhausted,
        nodes_explored: @nodes_explored
      )
    end

    private

    def search(assignment)
      return if budget_exhausted?

      # Admissible lower bound: unpinned packages can only add cost.
      return if lower_bound(assignment) >= @best_cost

      solution = solve_partial(assignment)
      return if solution.nil?

      cost = self.class.change_cost(solution, locked: @locked, costs: @costs)
      if cost < @best_cost
        @best_cost = cost
        @best_solution = solution
      end

      package = choose_branch_package(assignment, solution)
      return if package.nil?

      candidate_versions(package, solution).each do |version|
        search(assignment.merge(package => version))
        return if budget_exhausted?
      end
    end

    def solve_partial(assignment)
      @nodes_explored += 1
      source = PinnedSource.new(@source, assignment)
      decisions = VersionSolver.new(source: source, logger: @logger).solve
      decisions.reject { |package, _| Package.root?(package) }
    rescue SolveFailure => failure
      @root_failure = failure if assignment.empty?
      nil
    end

    def budget_exhausted?
      return false unless @max_nodes
      return false if @nodes_explored < @max_nodes

      @budget_exhausted = true
    end

    def lower_bound(assignment)
      assignment.sum(0) do |package, version|
        lower_bound_cost(package, version)
      end
    end

    def marginal_cost(package, version)
      @locked[package] == version ? 0 : @costs.fetch(package, DEFAULT_COST)
    end

    # Pinning restricts a package's version but cannot force it into the
    # solution, so a pinned package may still drop out entirely. The bound
    # therefore charges the cheapest way the package could end up:
    #
    # * pinned at its locked version: 0 (kept for free)
    # * pinned away from its locked version: its cost (paid whether the
    #   package is changed to the pinned version or removed outright)
    # * not present in the lockfile: 0 (it may simply never be selected)
    def lower_bound_cost(package, version)
      return 0 unless @locked.key?(package)

      marginal_cost(package, version)
    end

    # Branch on the not-yet-pinned package whose current version is most
    # expensive relative to the lockfile.
    def choose_branch_package(assignment, solution)
      candidates = solution.keys - assignment.keys
      return nil if candidates.empty?

      candidates.max_by do |package|
        [marginal_cost(package, solution[package]), package.to_s]
      end
    end

    # Cheapest versions first, preferring the version already in the
    # current solution so good incumbents are found early.
    def candidate_versions(package, solution)
      current = solution[package]
      @source.versions_for(package).sort_by do |version|
        [marginal_cost(package, version), version == current ? 0 : 1]
      end
    end
  end
end
