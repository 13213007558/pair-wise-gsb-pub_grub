require_relative 'platform_package'
require_relative 'rubygems'
require_relative 'version_constraint'
require_relative 'incompatibility'
require_relative 'basic_package_source'

module PubGrub
  # A package source that solves several target platforms at once while
  # producing a single shared lockfile.
  #
  # Rules:
  #
  # * A package version may declare the platforms on which it is available
  #   (StaticPackageSource::DSL#add +platforms:+). Versions are filtered per
  #   target platform.
  # * A dependency may declare the platforms on which it takes effect, either
  #   with the DSL helper +s.on(:linux) { ... }+ or by tagging a requirement
  #   with +platforms:+.
  # * A package needed on several platforms must resolve to the exact same
  #   version on all of them. This is enforced by cross-platform
  #   incompatibilities inside one joint solve (the platforms are never solved
  #   independently and stitched together afterwards).
  #
  # Example:
  #
  #   source = PubGrub::MultiPlatformPackageSource.new(:linux, :macos) do |s|
  #     s.root linux: { 'app' => '1.0.0' }, macos: { 'app' => '1.0.0' }
  #
  #     s.add 'app', '1.0.0', deps: {
  #       'shared' => '>= 1.0',
  #       'linux_only' => s.on(:linux) { '2.0.0' }
  #     }
  #     s.add 'shared', '1.2.0'
  #     s.add 'linux_only', '2.0.0', platforms: [:linux]
  #   end
  #
  #   PubGrub.solve_for_platforms(source)
  class MultiPlatformPackageSource < BasicPackageSource
    # A requirement that only applies on a subset of target platforms.
    PlatformDependency = Struct.new(:requirement, :platforms) do
      def initialize(requirement, platforms)
        super(requirement, Array(platforms).map(&:to_sym))
      end

      def applies_on?(platform)
        platforms.include?(platform.to_sym)
      end
    end

    class DSL
      def initialize(source)
        @source = source
      end

      # Declare the top-level requirements for each target platform:
      #
      #   s.root linux: { 'app' => '1.0.0' }, macos: { 'app' => '~> 2.0' }
      #
      # Platforms may also be given as strings. Platforms that are not part
      # of the solve are rejected.
      def root(deps_by_platform)
        deps_by_platform.each do |platform, deps|
          @source.set_root_dependencies(platform, deps)
        end
      end

      # Declare one version of a package.
      #
      # +platforms+ restricts where this version may be selected. Without it
      # the version is available on every target platform. +deps+ may contain
      # plain requirements (every platform) or PlatformDependency values
      # built with #on / #platform_only.
      def add(name, version, deps: {}, platforms: nil)
        @source.add_version(name, version, deps: deps, platforms: platforms)
      end

      # Build a dependency requirement that only applies on +platforms+.
      #
      #   s.add 'app', '1.0.0', deps: { 'kqueue' => s.on(:macos) { '~> 1.0' } }
      def on(*platforms)
        requirement = yield
        PlatformDependency.new(requirement, platforms)
      end

      # Alias conveying that the dependency belongs to one platform only.
      def platform_only(platform, &block)
        on(platform, &block)
      end
    end

    attr_reader :platforms

    def initialize(*platforms)
      raise ArgumentError, "at least one target platform is required" if platforms.empty?

      @platforms = platforms.flatten.map(&:to_sym).uniq
      raise ArgumentError, "at least one target platform is required" if @platforms.empty?

      # name => { version => { dep_name => requirement or PlatformDependency } }
      @packages = Hash.new { |h, name| h[name] = {} }
      # name => { version => [platform, ...] (nil means all platforms) }
      @version_platforms = Hash.new { |h, name| h[name] = {} }
      # platform => { dep_name => requirement }
      @root_deps = Hash.new { |h, platform| h[platform] = {} }

      yield DSL.new(self) if block_given?

      super()
    end

    # --- DSL-facing mutation API (also used directly by the tests) ---

    def set_root_dependencies(platform, deps)
      platform = normalize_platform!(platform)
      @root_deps[platform].merge!(deps)
    end

    def add_version(name, version, deps: {}, platforms: nil)
      version = Gem::Version.new(version)
      available = platforms.nil? ? nil : normalize_platforms!(platforms)

      if @packages[name].key?(version) || @version_platforms[name].key?(version)
        raise ArgumentError, "#{name} #{version} declared twice"
      end

      @version_platforms[name][version] = available
      @packages[name][version] = deps
    end

    # --- BasicPackageSource interface ---

    def all_versions_for(package)
      case package
      when PlatformPackage::Root
        [Package.root_version]
      when PlatformPackage
        versions_available_on(package.name, package.platform)
      else
        []
      end
    end

    def root_dependencies
      # The single global root depends on one synthetic root package per
      # platform, tying the joint solve together.
      @platforms.each_with_object({}) do |platform, deps|
        deps[platform_root(platform)] = Package.root_version
      end
    end

    def dependencies_for(package, version)
      case package
      when PlatformPackage::Root
        platform_deps = @root_deps.fetch(package.platform) { {} }
        platform_deps.each_with_object({}) do |(name, requirement), deps|
          deps[unit(name, package.platform)] = requirement
        end
      when PlatformPackage
        deps = @packages[package.name][version] || {}
        deps.each_with_object({}) do |(dep_name, value), active|
          if value.is_a?(PlatformDependency)
            next unless value.applies_on?(package.platform)
            value = value.requirement
          end
          active[unit(dep_name, package.platform)] = value
        end
      else
        {}
      end
    end

    def parse_dependency(package, dependency)
      case package
      when PlatformPackage::Root
        VersionConstraint.exact(package, Package.root_version)
      when PlatformPackage
        return false unless @packages.key?(package.name)
        return false if all_versions_for(package).empty?

        PubGrub::RubyGems.parse_constraint(package, dependency)
      else
        false
      end
    end

    # In addition to the usual dependency incompatibilities, enforce the
    # shared-lockfile rule: once <name> v is picked on one platform it cannot
    # coexist with a different version of <name> on another platform.
    def incompatibilities_for(package, version)
      dependency_incompatibilities(package, version) +
        cross_platform_incompatibilities(package, version)
    end

    # Split a joint solver result into packages common to every platform and
    # packages only needed by a subset of platforms.
    def partition_decisions(decisions)
      chosen = Hash.new { |h, name| h[name] = {} }

      decisions.each do |package, chosen_version|
        next unless package.is_a?(PlatformPackage) && !package.root?
        chosen[package.name][package.platform] = chosen_version
      end

      common = {}
      only_on = Hash.new { |h, platform| h[platform] = {} }

      chosen.each do |name, versions_by_platform|
        distinct_versions = versions_by_platform.values.uniq
        on_every_platform = versions_by_platform.keys.sort == @platforms.sort

        if on_every_platform && distinct_versions.size == 1
          common[name] = distinct_versions.first
        else
          # Either only needed on a subset of platforms, or the joint solve
          # picked differing versions; list it under each platform that needs
          # it so the lockfile can record the effective platform set.
          versions_by_platform.each do |platform, chosen_version|
            only_on[platform][name] = chosen_version
          end
        end
      end

      [common, only_on]
    end

    def unit(name, platform)
      PlatformPackage.new(name, platform)
    end

    def platform_root(platform)
      @platform_roots ||= {}
      @platform_roots[platform] ||= PlatformPackage::Root.new(platform)
    end

    private

    def normalize_platform!(platform)
      platform = platform.to_sym
      unless @platforms.include?(platform)
        raise ArgumentError,
          "unknown platform #{platform.inspect}; solving for #{@platforms.map(&:inspect).join(", ")}"
      end
      platform
    end

    def normalize_platforms!(platforms)
      Array(platforms).map { |platform| normalize_platform!(platform) }.uniq
    end

    def versions_available_on(name, platform)
      return [] unless @packages.key?(name)

      @packages[name].keys.select do |version|
        available = @version_platforms[name][version]
        available.nil? || available.include?(platform)
      end.sort
    end

    # Reimplementation of BasicPackageSource#incompatibilities_for without its
    # "adjacent versions with identical deps" widening: per-platform units mean
    # two adjacent versions of the same name can have different availability or
    # different effective dependencies, so exact terms are required.
    def dependency_incompatibilities(package, version)
      deps = @cached_dependencies[package][version]

      deps.map do |dep_package, dep_requirement|
        self_constraint = VersionConstraint.exact(package, version)

        dep_constraint = parse_dependency(dep_package, dep_requirement)
        unless dep_constraint
          cause = Incompatibility::InvalidDependency.new(dep_package, dep_requirement)
          next Incompatibility.new([Term.new(self_constraint, true)], cause: cause)
        end

        unless dep_constraint.is_a?(VersionConstraint)
          dep_constraint = VersionConstraint.new(dep_package, range: dep_constraint)
        end

        Incompatibility.new(
          [Term.new(self_constraint, true), Term.new(dep_constraint, false)],
          cause: :dependency
        )
      end
    end

    def cross_platform_incompatibilities(package, version)
      return [] unless package.is_a?(PlatformPackage) && !package.root?

      incompatibilities = []

      (@platforms - [package.platform]).each do |other_platform|
        other_unit = unit(package.name, other_platform)

        # Every pair of distinct versions across the two platforms is an
        # incompatibility with two positive terms. We must iterate over the
        # other platform's versions rather than only coupling this same
        # version: when a version is unavailable on the other platform there
        # is no matching positive term, which is exactly the case that rules
        # out the whole joint solve instead of silently decoupling the
        # platforms.
        versions_available_on(package.name, other_platform).each do |other_version|
          next if other_version == version

          mismatch = Incompatibility::PlatformVersionMismatch.new(
            package.name, version, [package.platform, other_platform]
          )
          incompatibilities << Incompatibility.new(
            [
              Term.new(VersionConstraint.exact(package, version), true),
              Term.new(VersionConstraint.exact(other_unit, other_version), true)
            ],
            cause: mismatch
          )
        end
      end

      incompatibilities
    end
  end
end
