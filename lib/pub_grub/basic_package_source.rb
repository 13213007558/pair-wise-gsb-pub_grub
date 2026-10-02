require_relative 'version_constraint'
require_relative 'incompatibility'
require_relative 'feature_package'
require_relative 'feature_dependency'

module PubGrub
  # Types:
  #
  # Where possible, PubGrub will accept user-defined types, so long as they quack.
  #
  # ## "Package":
  #
  # This class will be used to represent the various packages being solved for.
  # .to_s will be called when displaying errors and debugging info, it should
  # probably return the package's name.
  # It must also have a reasonable definition of #== and #hash
  #
  # Example classes: String ("rails")
  #
  #
  # ## "Version":
  #
  # This class will be used to represent a single version number.
  #
  # Versions don't need to store their associated package, however they will
  # only be compared against other versions of the same package.
  #
  # It must be Comparible (and implement <=> reasonably)
  #
  # Example classes: Gem::Version, Integer
  #
  #
  # ## "Dependency"
  #
  # This class represents the requirement one package has on another. It is
  # returned by dependencies_for(package, version) and will be passed to
  # parse_dependency to convert it to a format PubGrub understands.
  #
  # It must also have a reasonable definition of #==
  #
  # Example classes: String ("~> 1.0"), Gem::Requirement
  #
  class BasicPackageSource
    # Override me!
    #
    # This is called per package to find all possible versions of a package.
    #
    # It is called at most once per-package
    #
    # Returns: Array of versions for a package, in preferred order of selection
    def all_versions_for(package)
      raise NotImplementedError
    end

    # Override me!
    #
    # Returns: Hash in the form of { package => requirement, ... }
    def dependencies_for(package, version)
      raise NotImplementedError
    end

    # Override me to declare features available for a package version.
    #
    # Return a Hash in the form:
    #   { feature_name => { dependencies: { package => requirement }, features: [:other_feature] } }
    #
    # A feature declaration may also be just an Array of other features. The
    # feature named :default is activated for ordinary dependencies unless that
    # dependency explicitly sets default_features: false.
    def features_for(_package, _version)
      {}
    end

    # Override me!
    #
    # Convert a (user-defined) dependency into a format PubGrub understands.
    #
    # Package is passed to this method but for many implementations is not
    # needed.
    #
    # Returns: either a PubGrub::VersionRange, PubGrub::VersionUnion, or a
    #   PubGrub::VersionConstraint
    def parse_dependency(package, dependency)
      raise NotImplementedError
    end

    # Override me!
    #
    # If not overridden, this will call dependencies_for with the root package.
    #
    # Returns: Hash in the form of { package => requirement, ... } (see dependencies_for)
    def root_dependencies
      dependencies_for(@root_package, @root_version)
    end

    def initialize
      @root_package = Package.root
      @root_version = Package.root_version

      @sorted_versions = Hash.new do |h,k|
        if k == @root_package
          h[k] = [@root_version]
        else
          h[k] = all_versions_for(k).sort
        end
      end

      @cached_dependencies = Hash.new do |packages, package|
        if package == @root_package
          packages[package] = {
            @root_version => root_dependencies
          }
        else
          packages[package] = Hash.new do |versions, version|
            versions[version] = dependencies_for(package, version)
          end
        end
      end

      @cached_features = Hash.new do |packages, package|
        packages[package] = Hash.new do |versions, version|
          normalize_features(features_for(package, version))
        end
      end
    end

    def versions_for(package, range=VersionRange.any)
      if FeaturePackage.feature?(package)
        versions = @sorted_versions[package.package].select do |version|
          @cached_features[package.package][version].key?(package.feature)
        end
        return range.select_versions(versions)
      end

      range.select_versions(@sorted_versions[package])
    end

    def no_versions_incompatibility_for(_package, unsatisfied_term)
      cause = Incompatibility::NoVersions.new(unsatisfied_term)

      Incompatibility.new([unsatisfied_term], cause: cause)
    end

    def incompatibilities_for(package, version)
      return feature_incompatibilities_for(package, version) if FeaturePackage.feature?(package)

      package_deps = @cached_dependencies[package]
      sorted_versions = @sorted_versions[package]
      package_deps[version].flat_map do |dep_package, dep_constraint_name|
        low = high = sorted_versions.index(version)

        # find version low such that all >= low share the same dep
        while low > 0 &&
            package_deps[sorted_versions[low - 1]][dep_package] == dep_constraint_name
          low -= 1
        end
        low =
          if low == 0
            nil
          else
            sorted_versions[low]
          end

        # find version high such that all < high share the same dep
        while high < sorted_versions.length &&
            package_deps[sorted_versions[high]][dep_package] == dep_constraint_name
          high += 1
        end
        high =
          if high == sorted_versions.length
            nil
          else
            sorted_versions[high]
          end

        range = VersionRange.new(min: low, max: high, include_min: !low.nil?)

        self_constraint = VersionConstraint.new(package, range: range)

        dependency_incompatibilities(self_constraint, dep_package, dep_constraint_name)
      end
    end

    private

    def dependency_request(dependency)
      FeatureDependency.coerce(dependency)
    end

    def dependency_incompatibilities(self_constraint, dep_package, raw_dependency)
      request = dependency_request(raw_dependency)
      dependency_for_parsing =
        if FeatureDependency.feature_dependency?(raw_dependency) || raw_dependency.is_a?(Hash)
          request.constraint
        else
          raw_dependency
        end
      dep_constraint = parse_dependency(dep_package, dependency_for_parsing)

      if !dep_constraint
        cause = Incompatibility::InvalidDependency.new(dep_package, request.constraint)
        return [Incompatibility.new([Term.new(self_constraint, true)], cause: cause)]
      elsif !dep_constraint.is_a?(VersionConstraint)
        dep_constraint = VersionConstraint.new(dep_package, range: dep_constraint)
      end

      incompatibilities = []
      feature_self_dependency =
        self_constraint.package == dep_package &&
          FeatureDependency.feature_dependency?(raw_dependency) &&
            (!request.features.empty? || !request.default_features)

      unless feature_self_dependency
        incompatibilities << Incompatibility.new([
          Term.new(self_constraint, true),
          Term.new(dep_constraint, false)
        ], cause: :dependency)
      end
      if FeatureDependency.feature_dependency?(raw_dependency) || raw_dependency.is_a?(Hash)
        incompatibilities.concat(feature_request_incompatibilities(self_constraint, dep_package, request, dep_constraint))
      end
      incompatibilities
    end

    def feature_request_incompatibilities(self_constraint, dep_package, request, dep_constraint)
      versions = versions_for(dep_package, dep_constraint.range)
      return [] if versions.empty?

      versions.flat_map do |candidate|
        features = @cached_features[dep_package][candidate]
        requested_features = request.features.dup
        requested_features << :default if request.default_features && features.key?(:default)
        requested_features.uniq!

        feature_packages = requested_features.map do |feature|
          FeaturePackage.new(dep_package, feature)
        end

        missing, available = feature_packages.partition do |feature_package|
          !features.key?(feature_package.feature)
        end

        candidate_incompatibilities = []

        unless missing.empty?
          terms = [Term.new(self_constraint, true), Term.new(VersionConstraint.exact(dep_package, candidate), true)]
          candidate_incompatibilities << Incompatibility.new(
            terms,
            cause: Incompatibility::InvalidFeature.new(dep_package, missing.map(&:feature))
          )
        end

        available.each do |feature_package|
          terms = [
            Term.new(self_constraint, true),
            Term.new(VersionConstraint.exact(dep_package, candidate), true),
            Term.new(VersionConstraint.exact(feature_package, candidate), false)
          ]
          candidate_incompatibilities << Incompatibility.new(terms, cause: :feature_dependency)
        end

        candidate_incompatibilities
      end
    end

    def feature_incompatibilities_for(package, version)
      features = @cached_features[package.package][version]
      definition = features[package.feature]
      self_constraint = VersionConstraint.exact(package, version)

      unless definition
        cause = Incompatibility::InvalidFeature.new(package.package, package.feature)
        return [Incompatibility.new([Term.new(self_constraint, true)], cause: cause)]
      end

      incompatibilities = definition[:dependencies].flat_map do |dep_package, dependency|
        dependency_incompatibilities(self_constraint, dep_package, dependency)
      end

      definition[:features].each do |feature|
        feature_package = FeaturePackage.new(package.package, feature)
        incompatibilities << Incompatibility.new([
          Term.new(self_constraint, true),
          Term.new(VersionConstraint.exact(feature_package, version), false)
        ], cause: :dependency)
      end

      incompatibilities
    end

    def normalize_features(features)
      features.each_with_object({}) do |(name, definition), normalized|
        feature_name = name.to_s == "default" ? :default : name
        normalized[feature_name] =
          case definition
          when nil
            { dependencies: {}, features: [] }
          when Hash
            dependencies = definition[:dependencies] || definition[:packages]
            features =
              if dependencies || definition.key?(:features)
                Array(definition[:features])
              else
                []
              end
            {
              dependencies: dependencies || (definition.key?(:features) ? {} : definition),
              features: features
            }
          when Array
            { dependencies: {}, features: definition }
          else
            raise ArgumentError, "invalid feature declaration for #{name}: #{definition.inspect}"
          end
      end
    end
  end
end
