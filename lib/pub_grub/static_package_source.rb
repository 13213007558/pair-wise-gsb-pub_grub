require_relative 'package'
require_relative 'rubygems'
require_relative 'version_constraint'
require_relative 'incompatibility'
require_relative 'basic_package_source'

module PubGrub
  class StaticPackageSource < BasicPackageSource
    class DSL
      def initialize(packages, root_deps, package_features)
        @packages = packages
        @root_deps = root_deps
        @package_features = package_features
      end

      def root(deps:)
        @root_deps.update(deps)
      end

      def add(name, version, deps: {}, features: nil)
        version = Gem::Version.new(version)
        @packages[name] ||= {}
        raise ArgumentError, "#{name} #{version} declared twice" if @packages[name].key?(version)
        @packages[name][version] = clean_deps(name, version, deps)
        @package_features[name] ||= {}
        @package_features[name][version] = features || {}
      end

      private

      # Exclude redundant self-referencing dependencies
      def clean_deps(name, version, deps)
        deps.reject do |dep_name, req|
          if FeatureDependency.feature_dependency?(req) || req.is_a?(Hash)
            request = FeatureDependency.coerce(req)
            name == dep_name &&
              request.features.empty? &&
              request.default_features &&
              PubGrub::RubyGems.parse_range(request.constraint).include?(version)
          else
            name == dep_name && PubGrub::RubyGems.parse_range(req).include?(version)
          end
        end
      end
    end

    def initialize
      @root_deps = {}
      @packages = {}
      @package_features = {}

      yield DSL.new(@packages, @root_deps, @package_features)

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

    def features_for(package, version)
      @package_features.dig(package, version) || {}
    end

    def parse_dependency(package, dependency)
      dependency = dependency.constraint if dependency.is_a?(FeatureDependency)

      if FeaturePackage.feature?(package)
        return false unless @packages.key?(package.package)
        return VersionConstraint.any(package)
      end

      return false unless @packages.key?(package)

      PubGrub::RubyGems.parse_constraint(package, dependency)
    end
  end
end
