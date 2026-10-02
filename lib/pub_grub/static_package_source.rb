require_relative 'package'
require_relative 'rubygems'
require_relative 'dependency'
require_relative 'version_constraint'
require_relative 'incompatibility'
require_relative 'basic_package_source'

module PubGrub
  class StaticPackageSource < BasicPackageSource
    class DSL
      def initialize(packages, root_deps, features)
        @packages = packages
        @root_deps = root_deps
        @features = features
      end

      def root(deps:)
        deps.each do |name, dep|
          @root_deps[name] = Dependency.coerce(dep)
        end
      end

      # Declare a package version.
      #
      # deps: maps a dependency name to its requirement. A requirement
      #   may be a plain constraint (">= 1.0") or a Hash with
      #   :constraint, :features and :default_features keys, e.g.
      #
      #     deps: { 'net' => { constraint: '>= 1.0', features: ['tls'],
      #                        default_features: false } }
      #
      # features: declares the package's feature table. Each feature
      #   maps to a list of items, where an item is either the name of
      #   another feature of this package, or a package dependency
      #   (a single-pair Hash, or an explicit :package Hash), e.g.
      #
      #     features: {
      #       'default' => ['tls'],
      #       'tls' => ['compression', { 'native-tls' => '>= 0.1' }],
      #       'compression' => [],
      #     }
      def add(name, version, deps: {}, features: {})
        version = Gem::Version.new(version)
        @packages[name] ||= {}
        @features[name] ||= {}
        raise ArgumentError, "#{name} #{version} declared twice" if @packages[name].key?(version)
        @packages[name][version] = clean_deps(name, version, deps)
        @features[name][version] = normalize_features(features)
      end

      private

      # Exclude redundant self-referencing dependencies
      def clean_deps(name, version, deps)
        deps.each_with_object({}) do |(dep_name, req), cleaned|
          dep = Dependency.coerce(req)
          next if name == dep_name && PubGrub::RubyGems.parse_range(dep.constraint).include?(version)

          cleaned[dep_name] = dep
        end
      end

      def normalize_features(features)
        features.each_with_object({}) do |(feature, items), table|
          table[feature.to_s] = Array(items).map { |item| normalize_feature_item(item) }
        end
      end

      def normalize_feature_item(item)
        case item
        when String, Symbol
          item.to_s
        when Hash
          if item.key?(:package) || item.key?('package')
            [item[:package] || item['package'], Dependency.coerce(item)]
          else
            dep_name, req = item.first
            [dep_name, Dependency.coerce(req)]
          end
        else
          raise ArgumentError, "invalid feature item: #{item.inspect}"
        end
      end
    end

    def initialize
      @root_deps = {}
      @packages = {}
      @features = {}

      yield DSL.new(@packages, @root_deps, @features)

      super()
    end

    def all_versions_for(package)
      @packages[package].keys
    end

    def root_dependencies
      @root_deps
    end

    def dependencies_for(package, version)
      @packages[package][version]
    end

    # Returns the declared feature table for a package version, in the
    # form of { feature => [item, ...] }, where an item is either a
    # feature name (String) or a [package, PubGrub::Dependency] pair.
    def features_for(package, version)
      @features.fetch(package, {}).fetch(version, {})
    end

    def parse_dependency(package, dependency)
      return false unless @packages.key?(package)

      dependency = dependency.constraint if dependency.is_a?(Dependency)

      PubGrub::RubyGems.parse_constraint(package, dependency)
    end
  end
end
