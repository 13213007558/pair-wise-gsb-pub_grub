module PubGrub
  # Tracks which features are activated on each package as the solver
  # makes (and un-makes) version decisions.
  #
  # Whenever the solver decides a version for a package, that version's
  # dependency edges are registered here (#add_edge), tagged with the
  # current decision level. When the solver backtracks, edges introduced
  # by the retracted decisions are dropped (#backtrack), so no
  # activation state unique to the abandoned path survives.
  #
  # Activation is recomputed from scratch from the live edges:
  #
  # * requested features are the union of the features requested by
  #   every live incoming edge; one edge can never erase another
  #   edge's requests
  # * the +default+ feature is enabled when _any_ live incoming edge
  #   enables default features; a single edge opting out
  #   (+default_features: false+) cannot disable it for the others
  # * a feature may pull in other features of the same package or
  #   dependencies on other packages; the closure is computed over the
  #   finite declared feature tables, so cyclic feature declarations
  #   terminate
  #
  # Every activated feature also records the base edges responsible for
  # its activation. Feature dependencies are reported together with
  # those edges so the solver can make the resulting incompatibilities
  # conditional on the activating decisions.
  class FeatureActivation
    Edge = Struct.new(:level, :from, :from_version, :package, :dependency)

    attr_reader :features, :feature_dependencies

    def initialize(source)
      @source = source
      @edges = []
      @features = {}
      @feature_dependencies = []
    end

    def add_edge(from, from_version, package, dependency, level)
      @edges << Edge.new(level, from, from_version, package, dependency)
    end

    def backtrack(level)
      @edges.reject! { |edge| edge.level > level }
    end

    # Recompute activation from the live edges.
    #
    # +decided+ is a Hash of currently decided packages to their
    # versions (typically PartialSolution#decisions).
    #
    # Fills #features ({ package => [feature, ...] }) and
    # #feature_dependencies ([[from_package, from_version, to_package,
    # dependency, responsible_edges], ...]).
    def recompute(decided)
      @features = {}
      @feature_dependencies = []

      requests = Hash.new { |h, k| h[k] = [] }
      @edges.each do |edge|
        requests[edge.package] << edge
      end

      # [package, feature] => Array<Edge> responsible for its activation
      responsible = Hash.new { |h, k| h[k] = [] }
      # [from, version, to, dependency] => Array<Edge>
      dependency_edges = Hash.new { |h, k| h[k] = [] }

      visited = {}
      queue = []

      activate = lambda do |package, feature, edges|
        key = [package, feature]
        list = responsible[key]
        grew = false
        edges.each do |edge|
          next if list.include?(edge)

          list << edge
          grew = true
        end

        if !visited[key]
          visited[key] = true
          queue << key
        elsif grew
          # re-expand with the grown responsible set
          queue << key
        end
      end

      seed = lambda do |package, dependency, edges|
        activate.call(package, 'default', edges) if default_features?(dependency)
        requested_features(dependency).each do |feature|
          activate.call(package, feature, edges)
        end
      end

      decided.each_key do |package|
        requests[package].each do |edge|
          seed.call(package, edge.dependency, [edge])
        end
      end

      until queue.empty?
        package, feature = queue.shift
        version = decided[package]
        next unless version

        items = declared_features(package, version)[feature]
        next unless items

        resp = responsible[[package, feature]]

        features = (@features[package] ||= [])
        features << feature unless features.include?(feature)

        items.each do |item|
          case item
          when String
            activate.call(package, item, resp)
          else
            dep_package, dependency = item
            key = [package, version, dep_package, dependency]
            list = dependency_edges[key]
            resp.each do |edge|
              list << edge unless list.include?(edge)
            end
            seed.call(dep_package, dependency, resp) if decided.key?(dep_package)
          end
        end
      end

      @feature_dependencies = dependency_edges.map do |(package, version, dep_package, dependency), edges|
        [package, version, dep_package, dependency, edges]
      end

      @features.each_value(&:sort!)

      self
    end

    private

    def declared_features(package, version)
      @source.features_for(package, version) || {}
    end

    def requested_features(dependency)
      dependency.respond_to?(:features) ? dependency.features : []
    end

    def default_features?(dependency)
      dependency.respond_to?(:default_features?) ? dependency.default_features? : true
    end
  end
end
