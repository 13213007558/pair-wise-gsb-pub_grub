require_relative 'package'
require_relative 'rubygems'
require_relative 'version_constraint'
require_relative 'incompatibility'
require_relative 'basic_package_source'

module PubGrub
  class StaticPackageSource < BasicPackageSource
    class DSL
      def initialize(packages, capabilities, providers, root_deps)
        @packages = packages
        @capabilities = capabilities
        @providers = providers
        @root_deps = root_deps
      end

      def root(deps:)
        @root_deps.update(deps)
      end

      def add(name, version, deps: {})
        raise ArgumentError, "#{name.inspect} is already declared as a capability" if @capabilities.key?(name)

        version = Gem::Version.new(version)
        @packages[name] ||= {}
        raise ArgumentError, "#{name} #{version} declared twice" if @packages[name].key?(version)
        @packages[name][version] = clean_deps(name, version, deps)
      end

      def provides(capability, capability_version, by:, version:)
        raise ArgumentError, "#{capability.inspect} is already declared as a package" if @packages.key?(capability)

        package_version = Gem::Version.new(version)
        unless @packages.dig(by, package_version)
          raise ArgumentError, "#{by} #{package_version} must be added before it provides #{capability}"
        end

        @capabilities[capability] = true
        providers = @providers[capability]
        if providers.any? { |provider| provider[:package] == by && provider[:version] == package_version }
          raise ArgumentError, "#{by} #{package_version} provides #{capability} twice"
        end

        providers << {
          package: by,
          version: package_version,
          capability_version: Gem::Version.new(capability_version)
        }
      end

      private

      # Exclude redundant self-referencing dependencies
      def clean_deps(name, version, deps)
        deps.reject {|dep_name, req| name == dep_name && PubGrub::RubyGems.parse_range(req).include?(version) }
      end
    end

    def initialize
      @root_deps = {}
      @packages = {}
      @capabilities = {}
      @providers = Hash.new { |hash, capability| hash[capability] = [] }

      yield DSL.new(@packages, @capabilities, @providers, @root_deps)

      super()
    end

    def all_versions_for(package)
      return provider_versions_for(package) if capability?(package)

      @packages[package].keys
    end

    def root_dependencies
      @root_deps
    end

    def dependencies_for(package, version)
      return [] if capability?(package)

      @packages[package][version]
    end

    def parse_dependency(package, dependency)
      return false unless @packages.key?(package) || capability?(package)

      PubGrub::RubyGems.parse_constraint(package, dependency)
    end

    def incompatibilities_for(package, version)
      return capability_incompatibilities_for(package, version) if capability?(package)

      [*super, *mutually_exclusive_incompatibilities_for(package, version)]
    end

    def no_versions_incompatibility_for(package, unsatisfied_term)
      if capability?(package) && !@providers.key?(package)
        cause = Incompatibility::NoProviders.new(package, [])
        return Incompatibility.new([unsatisfied_term], cause: cause)
      elsif capability?(package)
        providers = @providers[package].map { |provider| provider[:package] }.uniq
        cause = Incompatibility::NoProviders.new(package, providers)
        return Incompatibility.new([unsatisfied_term], cause: cause)
      end

      super
    end

    private

    def capability?(package)
      @capabilities.key?(package)
    end

    def provider_versions_for(capability)
      @providers[capability].each_with_index.map do |provider, preference|
        ProviderVersion.for(
          capability_version: provider[:capability_version],
          package: provider[:package],
          version: provider[:version],
          preference: preference
        )
      end.sort
    end

    def capability_incompatibilities_for(capability, provider_version)
      provider_constraint = VersionConstraint.exact(provider_version.package, provider_version.version)
      capability_constraint = VersionConstraint.exact(capability, provider_version)

      provision = Incompatibility.new([
        Term.new(capability_constraint, true),
        Term.new(provider_constraint, false)
      ], cause: Incompatibility::CapabilityProvision.new(
        capability,
        provider_version.capability_version,
        provider_version.package,
        provider_version.version
      ))

      [provision]
    end

    def mutually_exclusive_incompatibilities_for(package, version)
      @providers.flat_map do |capability, providers|
        next [] unless providers.any? { |provider| provider[:package] == package && provider[:version] == version }

        providers.filter_map do |provider|
          next if provider[:package] == package
          if package.to_s < provider[:package].to_s
            left_package, left_version = package, version
            right_package, right_version = provider[:package], provider[:version]
          elsif package.to_s > provider[:package].to_s
            left_package, left_version = provider[:package], provider[:version]
            right_package, right_version = package, version
          elsif provider[:version] == version
            next
          else
            left_package, left_version = package, [version, provider[:version]].min
            right_package, right_version = package, [version, provider[:version]].max
          end

          Incompatibility.new([
            Term.new(VersionConstraint.exact(left_package, left_version), true),
            Term.new(VersionConstraint.exact(right_package, right_version), true)
          ], cause: Incompatibility::MutuallyExclusiveProviders.new(
            capability,
            left_package, left_version,
            right_package, right_version
          ))
        end
      end
    end
  end
end
