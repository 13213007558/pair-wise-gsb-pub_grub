require_relative 'partial_solution'
require_relative 'term'
require_relative 'incompatibility'
require_relative 'solve_failure'
require_relative 'strategy'
require_relative 'feature_activation'

module PubGrub
  class VersionSolver
    attr_reader :logger
    attr_reader :source
    attr_reader :solution
    attr_reader :strategy

    def initialize(source:, root: Package.root, strategy: Strategy.new(source), logger: PubGrub.logger)
      @logger = logger

      @source = source
      @strategy = strategy

      # { package => [incompatibility, ...]}
      @incompatibilities = Hash.new do |h, k|
        h[k] = []
      end

      @seen_incompatibilities = {}

      @solution = PartialSolution.new

      # Feature activation is only tracked for sources which declare
      # features (see StaticPackageSource)
      @features_enabled = source.respond_to?(:features_for)
      if @features_enabled
        @feature_activation = FeatureActivation.new(source)
        # Incompatibilities introduced by active feature dependencies.
        # Unlike version dependency incompatibilities, these are
        # conditional: they are retracted when the activation which
        # introduced them is rolled back.
        @feature_incompatibilities = {}
      end

      add_incompatibility Incompatibility.new([
        Term.new(VersionConstraint.any(root), false)
      ], cause: :root)

      propagate(root)
    end

    # The features activated on each package by the current solution,
    # in the form of { package => [feature, ...] }
    def features
      return {} unless @features_enabled

      @feature_activation.features
    end

    def solved?
      solution.unsatisfied.empty?
    end

    # Returns true if there is more work to be done, false otherwise
    def work
      unsatisfied_terms = solution.unsatisfied
      if unsatisfied_terms.empty?
        logger.info { "Solution found after #{solution.attempted_solutions} attempts:" }
        solution.decisions.each do |package, version|
          next if Package.root?(package)
          logger.info { "* #{package} #{version}" }
        end

        return false
      end

      next_package = choose_package_version_from(unsatisfied_terms)
      propagate(next_package)

      true
    end

    def solve
      while work; end

      solution.decisions
    end

    alias_method :result, :solve

    private

    def propagate(initial_package)
      changed = [initial_package]
      while package = changed.shift
        @incompatibilities[package].reverse_each do |incompatibility|
          result = propagate_incompatibility(incompatibility)
          if result == :conflict
            root_cause = resolve_conflict(incompatibility)
            changed.clear
            changed << propagate_incompatibility(root_cause)
          elsif result # should be a Package
            changed << result
          end
        end
        changed.uniq!
      end
    end

    def propagate_incompatibility(incompatibility)
      unsatisfied = nil
      incompatibility.terms.each do |term|
        relation = solution.relation(term)
        if relation == :disjoint
          return nil
        elsif relation == :overlap
          # If more than one term is inconclusive, we can't deduce anything
          return nil if unsatisfied
          unsatisfied = term
        end
      end

      if !unsatisfied
        return :conflict
      end

      logger.debug { "derived: #{unsatisfied.invert}" }

      solution.derive(unsatisfied.invert, incompatibility)

      unsatisfied.package
    end

    def choose_package_version_from(unsatisfied_terms)
      remaining = unsatisfied_terms.map { |t| [t.package, t.constraint.range] }.to_h

      package, version = strategy.next_package_and_version(remaining)

      logger.debug { "attempting #{package} #{version}" }

      if version.nil?
        unsatisfied_term = unsatisfied_terms.find { |t| t.package == package }
        add_incompatibility source.no_versions_incompatibility_for(package, unsatisfied_term)
        return package
      end

      conflict = false

      source.incompatibilities_for(package, version).each do |incompatibility|
        if @seen_incompatibilities.include?(incompatibility)
          logger.debug { "knew: #{incompatibility}" }
          next
        end
        @seen_incompatibilities[incompatibility] = true

        add_incompatibility incompatibility

        conflict ||= incompatibility.terms.all? do |term|
          term.package == package || solution.satisfies?(term)
        end
      end

      unless conflict
        logger.info { "selected #{package} #{version}" }

        solution.decide(package, version)
        activate_features_for(package, version) if @features_enabled
      else
        logger.info { "conflict: #{conflict.inspect}" }
      end

      package
    end

    # Register the dependency edges of a freshly decided version and
    # activate any features they request
    def activate_features_for(package, version)
      deps =
        if Package.root?(package)
          source.root_dependencies
        else
          source.dependencies_for(package, version)
        end

      level = solution.decision_level
      deps.each do |dep_package, dependency|
        @feature_activation.add_edge(package, version, dep_package, dependency, level)
      end

      sync_feature_dependencies.each do |changed_package|
        propagate(changed_package) unless changed_package == package
      end
    end

    # Drop the edges introduced by retracted decisions and retract any
    # feature dependency incompatibilities which are no longer active,
    # so no activation state unique to the abandoned path survives
    def rollback_features(level)
      @feature_activation.backtrack(level)
      sync_feature_dependencies
    end

    # Recompute feature activation and reconcile the feature dependency
    # incompatibilities with it, adding newly activated ones and
    # retracting deactivated ones.
    #
    # Returns the packages whose incompatibilities were added and thus
    # need propagation.
    def sync_feature_dependencies
      @feature_activation.recompute(solution.decisions)

      desired = {}
      @feature_activation.feature_dependencies.each do |from, version, dep_package, dependency, edges|
        edges.each do |edge|
          incompatibility = build_feature_incompatibility(from, version, dep_package, dependency, edge)
          desired[incompatibility] = true
        end
      end

      @feature_incompatibilities.each_key do |incompatibility|
        next if desired.key?(incompatibility)

        incompatibility.terms.each do |term|
          @incompatibilities[term.package].delete(incompatibility)
        end
      end
      @feature_incompatibilities.keep_if { |incompatibility, _| desired.key?(incompatibility) }

      changed = []
      desired.each_key do |incompatibility|
        next if @feature_incompatibilities.key?(incompatibility)

        @feature_incompatibilities[incompatibility] = true
        add_incompatibility(incompatibility)
        changed << incompatibility.terms.first.package
      end
      changed
    end

    # A feature dependency is conditional both on the version declaring
    # it and on the decision whose edge activated the feature, so that
    # backtracking either one dissolves it
    def build_feature_incompatibility(package, version, dep_package, dependency, activator)
      terms = [Term.new(VersionConstraint.exact(package, version), true)]
      if activator && !Package.root?(activator.from)
        terms << Term.new(VersionConstraint.exact(activator.from, activator.from_version), true)
      end

      dep_constraint = source.parse_dependency(dep_package, dependency)
      if !dep_constraint
        cause = Incompatibility::InvalidDependency.new(dep_package, dependency)
        return Incompatibility.new(terms, cause: cause)
      end

      if !dep_constraint.is_a?(VersionConstraint)
        dep_constraint = VersionConstraint.new(dep_package, range: dep_constraint)
      end
      terms << Term.new(dep_constraint, false)

      cause = terms.length == 2 ? :dependency : :feature_dependency
      Incompatibility.new(terms, cause: cause)
    end

    def resolve_conflict(incompatibility)
      logger.info { "conflict: #{incompatibility}" }

      new_incompatibility = nil

      while !incompatibility.failure?
        most_recent_term = nil
        most_recent_satisfier = nil
        difference = nil

        previous_level = 1

        incompatibility.terms.each do |term|
          satisfier = solution.satisfier(term)

          if most_recent_satisfier.nil?
            most_recent_term = term
            most_recent_satisfier = satisfier
          elsif most_recent_satisfier.index < satisfier.index
            previous_level = [previous_level, most_recent_satisfier.decision_level].max
            most_recent_term = term
            most_recent_satisfier = satisfier
            difference = nil
          else
            previous_level = [previous_level, satisfier.decision_level].max
          end

          if most_recent_term == term
            difference = most_recent_satisfier.term.difference(most_recent_term)
            if difference.empty?
              difference = nil
            else
              difference_satisfier = solution.satisfier(difference.inverse)
              previous_level = [previous_level, difference_satisfier.decision_level].max
            end
          end
        end

        if previous_level < most_recent_satisfier.decision_level ||
            most_recent_satisfier.decision?

          logger.info { "backtracking to #{previous_level}" }
          solution.backtrack(previous_level)
          rollback_features(previous_level) if @features_enabled

          if new_incompatibility
            add_incompatibility(new_incompatibility)
          end

          return incompatibility
        end

        new_terms = []
        new_terms += incompatibility.terms - [most_recent_term]
        new_terms += most_recent_satisfier.cause.terms.reject { |term|
          term.package == most_recent_satisfier.term.package
        }
        if difference
          new_terms << difference.invert
        end

        new_incompatibility = Incompatibility.new(new_terms, cause: Incompatibility::ConflictCause.new(incompatibility, most_recent_satisfier.cause))

        if incompatibility.to_s == new_incompatibility.to_s
          logger.info { "!! failed to resolve conflicts, this shouldn't have happened" }
          break
        end

        incompatibility = new_incompatibility

        partially = difference ? " partially" : ""
        logger.info { "! #{most_recent_term} is#{partially} satisfied by #{most_recent_satisfier.term}" }
        logger.info { "! which is caused by #{most_recent_satisfier.cause}" }
        logger.info { "! thus #{incompatibility}" }
      end

      raise SolveFailure.new(incompatibility)
    end

    def add_incompatibility(incompatibility)
      logger.debug { "fact: #{incompatibility}" }
      incompatibility.terms.each do |term|
        package = term.package
        @incompatibilities[package] << incompatibility
      end
    end
  end
end
