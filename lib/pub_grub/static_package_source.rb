require_relative 'package'
require_relative 'rubygems'
require_relative 'version_constraint'
require_relative 'version_union'
require_relative 'incompatibility'
require_relative 'basic_package_source'
require_relative 'capability_version'

module PubGrub
  class StaticPackageSource < BasicPackageSource
    class DSL
      def initialize(packages, root_deps, provides, conflicts)
        @packages = packages
        @root_deps = root_deps
        @provides = provides
        @conflicts = conflicts
      end

      def root(deps:)
        @root_deps.update(deps)
      end

      def add(name, version, deps: {}, provides: {}, conflicts: [])
        version = Gem::Version.new(version)
        @packages[name] ||= {}
        raise ArgumentError, "#{name} #{version} declared twice" if @packages[name].key?(version)
        @packages[name][version] = clean_deps(name, version, deps)

        unless provides.empty?
          (@provides[name] ||= {})[version] = provides
        end

        unless conflicts.empty?
          (@conflicts[name] ||= {})[version] = normalize_conflicts(conflicts)
        end
      end

      private

      def normalize_conflicts(conflicts)
        if conflicts.is_a?(Array)
          conflicts.to_h { |name| [name, '>= 0'] }
        else
          conflicts
        end
      end

      # Exclude redundant self-referencing dependencies
      def clean_deps(name, version, deps)
        deps.reject {|dep_name, req| name == dep_name && PubGrub::RubyGems.parse_range(req).include?(version) }
      end
    end

    def initialize
      @root_deps = {}
      @packages = {}
      @provides = {}
      @conflicts = {}
      @capabilities = {}

      yield DSL.new(@packages, @root_deps, @provides, @conflicts)

      build_capability_packages

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

    def parse_dependency(package, dependency)
      return false unless @packages.key?(package)
      return dependency if dependency.is_a?(VersionRange) || dependency.is_a?(VersionUnion)

      constraint = PubGrub::RubyGems.parse_constraint(package, dependency)
      return constraint unless @capabilities.key?(package)

      convert_capability_constraint(package, constraint.range)
    end

    def incompatibilities_for(package, version)
      incompatibilities = super

      if (package_conflicts = @conflicts[package]) && (conflicts = package_conflicts[version])
        conflicts.each do |other, requirement|
          incompatibilities << Incompatibility.new(
            [
              Term.new(VersionConstraint.exact(package, version), true),
              Term.new(PubGrub::RubyGems.parse_constraint(other, requirement), true),
            ],
            cause: :conflict,
            custom_explanation: conflict_explanation(package, version, other, requirement)
          )
        end
      end

      incompatibilities
    end

    # Splits a raw solution into the real packages and the capability
    # provisions, describing which provider was selected for each
    # capability.
    #
    # Returns:
    #   {
    #     packages: { package => version, ... },
    #     capabilities: {
    #       capability => { version:, provider:, provider_version: }, ...
    #     }
    #   }
    def describe_solution(decisions)
      packages = {}
      capabilities = {}

      decisions.each do |package, version|
        next if Package.root?(package)

        if version.is_a?(CapabilityVersion)
          capabilities[package] = {
            version: version.capability_version,
            provider: version.provider,
            provider_version: decisions[version.provider],
          }
        else
          packages[package] = version
        end
      end

      { packages: packages, capabilities: capabilities }
    end

    private

    # Rewrites a constraint over a capability package so its bounds are
    # capability versions, matching exactly the set of versions the original
    # (plain) constraint selects.
    #
    # Capability versions from different providers can share the same numeric
    # version, so a plain bound (e.g. >= 2.0.0) is not a precise boundary in
    # the capability version ordering: ">= 2.0.0 (provided by mini-image)"
    # must not cover "2.0.0 (provided by fast-image)". Expressing constraints
    # with capability version bounds keeps all range algebra exact.
    #
    # Constraints selecting no versions are returned unchanged, so failure
    # messages keep the original requirement.
    def convert_capability_constraint(package, constraint)
      if constraint.is_a?(VersionUnion)
        ranges = constraint.ranges.map do |range|
          convert_capability_range(package, range)
        end.compact

        return constraint if ranges.empty?

        VersionUnion.union(ranges)
      else
        convert_capability_range(package, constraint) || constraint
      end
    end

    def convert_capability_range(package, range)
      return range if range.any? || range.empty?

      versions = @sorted_versions[package]
      selected = range.select_versions(versions)
      return nil if selected.empty?

      min = selected.first == versions.first ? nil : selected.first
      max = selected.last == versions.last ? nil : selected.last

      VersionRange.new(min: min, max: max, include_min: !min.nil?, include_max: !max.nil?)
    end

    # Each capability becomes a synthetic package whose versions are
    # CapabilityVersions, one per (capability version, provider) pair.
    # Depending on the synthetic package picks exactly one provider, and
    # the provider's own dependencies are pulled in through a dependency
    # on the real package.
    def build_capability_packages
      capabilities = Hash.new { |h, k| h[k] = {} }

      @provides.each do |provider, versions|
        versions.each do |package_version, provides|
          provides.each do |capability, capability_version|
            if @packages.key?(capability)
              raise ArgumentError, "#{capability} is both a real package and a capability"
            end

            provided = CapabilityVersion.new(capability_version, provider)
            entry = (capabilities[capability][provided] ||= [])
            entry << package_version
          end
        end
      end

      capabilities.each do |capability, entries|
        @capabilities[capability] = true
        @packages[capability] = {}

        # Prefer higher capability versions, then later providers
        entries.keys.sort.reverse_each do |provided|
          provider_versions = entries[provided].sort
          ranges = provider_versions.map do |v|
            VersionRange.new(min: v, max: v, include_min: true, include_max: true)
          end
          @packages[capability][provided] = { provided.provider => VersionUnion.union(ranges) }
        end
      end
    end

    def conflict_explanation(package, version, other, requirement)
      requirement = Array(requirement).join(', ')
      suffix = requirement == '>= 0' ? '' : " #{requirement}"
      "#{package} #{version} conflicts with #{other}#{suffix}"
    end
  end
end
