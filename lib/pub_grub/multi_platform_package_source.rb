require_relative 'basic_package_source'
require_relative 'rubygems'
require 'set'

module PubGrub
  class MultiPlatformPackageSource < BasicPackageSource
    PlatformDependency = Struct.new(
      :package,
      :requirement,
      :platforms,
      keyword_init: true
    )

    PlatformDependencyCause = Struct.new(
      :parent,
      :version,
      :dependency,
      :platform,
      keyword_init: true
    )

    PlatformAvailability = Struct.new(
      :package,
      :version,
      :platform,
      keyword_init: true
    )

    PlatformMarker = Struct.new(:platform, keyword_init: true) do
      def to_s
        "platform #{platform}"
      end
    end

    PlatformPresence = Struct.new(:package, :platform, keyword_init: true) do
      def to_s
        "#{package} on #{platform}"
      end
    end

    class DSL
      def initialize(source, target_platforms)
        @source = source
        @target_platforms = target_platforms
      end

      def root(deps: {}, **platform_deps)
        add_root_deps(deps, @target_platforms)

        platform_deps.each do |platform, deps_for_platform|
          add_root_deps(deps_for_platform, platform)
        end
      end

      def add(name, version, platforms: @target_platforms, deps: {}, platform_deps: {})
        dependencies = []

        deps.each do |dependency, requirement|
          dependencies << PlatformDependency.new(
            package: dependency.to_s,
            requirement: requirement,
            platforms: @target_platforms
          )
        end

        platform_deps.each do |dependency, options|
          conditions = options.is_a?(Array) ? options : [options]
          conditions.each do |condition|
            dependencies << PlatformDependency.new(
              package: dependency.to_s,
              requirement: condition.fetch(:requirement),
              platforms: Array(condition.fetch(:platforms))
            )
          end
        end

        @source.add_version(name, version, Array(platforms), dependencies)
      end

      private

      def add_root_deps(deps, platforms)
        deps.each do |package, requirement|
          @source.add_root_dependency(package.to_s, requirement, Array(platforms))
        end
      end
    end

    def initialize(platforms)
      @target_platforms = Array(platforms).freeze
      raise ArgumentError, "at least one target platform is required" if @target_platforms.empty?
      raise ArgumentError, "target platforms must be unique" unless @target_platforms.uniq == @target_platforms

      @root_deps = []
      @packages = {}
      @marker_packages = @target_platforms.to_h do |platform|
        marker = PlatformMarker.new(platform: platform)
        [marker, platform]
      end
      @presence_packages = {}

      yield DSL.new(self, @target_platforms) if block_given?

      super()
    end

    attr_reader :target_platforms

    def marker_package?(package)
      @marker_packages.key?(package)
    end

    def presence_package?(package)
      @presence_packages.key?(package)
    end

    def presence_package(package, platform)
      presence = PlatformPresence.new(package: package, platform: platform)
      @presence_packages[presence] ||= presence
    end

    def add_root_dependency(package, requirement, platforms)
      validate_platforms!(platforms)
      @root_deps << PlatformDependency.new(
        package: package,
        requirement: requirement,
        platforms: platforms
      )
    end

    def add_version(name, version, version_platforms, dependencies)
      validate_platforms!(version_platforms)
      dependencies.each { |dependency| validate_platforms!(dependency.platforms) }

      name = name.to_s
      version = Gem::Version.new(version)
      package = @packages[name] ||= {
        versions: {},
        dependencies: Hash.new { |deps, dep_version| deps[dep_version] = [] }
      }

      raise ArgumentError, "#{name} #{version} declared twice" if package[:versions].key?(version)

      dependencies.each do |dependency|
        unless version_platforms & dependency.platforms == dependency.platforms
          raise ArgumentError, "#{name} #{version} cannot depend on #{dependency.package} on unavailable platforms"
        end
      end

      package[:versions][version] = version_platforms
      package[:dependencies][version].concat(dependencies)
    end

    def all_versions_for(package)
      if marker_package?(package)
        [1]
      elsif presence_package?(package)
        presence = @presence_packages[package]
        package_available_on?(presence.package, presence.platform) ? [1] : []
      else
        @packages.fetch(package)[:versions].keys
      end
    end

    def root_dependencies
      {}
    end

    def dependencies_for(_package, _version)
      {}
    end

    def parse_dependency(package, dependency)
      return false unless @packages.key?(package)

      PubGrub::RubyGems.parse_constraint(package, dependency)
    end

    def no_versions_incompatibility_for(package, unsatisfied_term)
      if presence_package?(package)
        presence = @presence_packages[package]
        return Incompatibility.new(
          [Term.new(unsatisfied_term.constraint, true)],
          cause: Incompatibility::NoVersions.new(unsatisfied_term.constraint),
          custom_explanation: "#{presence.package} has no versions available on #{presence.platform}"
        )
      end

      super
    end

    def incompatibilities_for(package, version)
      return root_incompatibilities if Package.root?(package)
      return marker_incompatibilities(package) if marker_package?(package)
      return [] if presence_package?(package)

      availability_incompatibilities(package, version) +
        dependency_incompatibilities(package, version)
    end

    def result_for(decisions)
      MultiPlatformSolution.from_decisions(self, decisions)
    end

    private

    def validate_platforms!(platforms)
      raise ArgumentError, "platform list must not be empty" if platforms.empty?

      unknown = platforms - @target_platforms
      return if unknown.empty?

      raise ArgumentError, "unknown platform(s): #{unknown.join(', ')}"
    end

    def root_incompatibilities
      @marker_packages.map do |marker, platform|
        Incompatibility.new(
          [
            Term.new(VersionConstraint.exact(Package.root, Package.root_version), true),
            Term.new(VersionConstraint.exact(marker, 1), false)
          ],
          cause: :dependency,
          custom_explanation: "root requires #{marker}"
        )
      end
    end

    def marker_incompatibilities(marker)
      platform = @marker_packages.fetch(marker)

      @root_deps.filter_map do |dependency|
        next unless dependency.platforms.include?(platform)

        unless @packages.key?(dependency.package)
          next Incompatibility.new(
            [Term.new(VersionConstraint.exact(marker, 1), true)],
            cause: Incompatibility::InvalidDependency.new(dependency.package, dependency.requirement),
            custom_explanation: "#{platform} requires unknown package #{dependency.package}"
          )
        end

        presence = presence_package(dependency.package, platform)
        constraint = parse_dependency(dependency.package, dependency.requirement)
        presence_incompatibility = Incompatibility.new(
          [
            Term.new(VersionConstraint.exact(marker, 1), true),
            Term.new(VersionConstraint.exact(presence, 1), false)
          ],
          cause: PlatformDependencyCause.new(
            parent: Package.root,
            version: Package.root_version,
            dependency: dependency.package,
            platform: platform
          ),
          custom_explanation: "#{platform} requires #{dependency.package}"
        )
        requirement_incompatibility = Incompatibility.new(
          [
            Term.new(VersionConstraint.exact(marker, 1), true),
            Term.new(constraint, false)
          ],
          cause: PlatformDependencyCause.new(
            parent: Package.root,
            version: Package.root_version,
            dependency: dependency.package,
            platform: platform
          ),
          custom_explanation: "#{platform} requires #{dependency.package} #{constraint.range}"
        )

        [presence_incompatibility, requirement_incompatibility]
      end
      .flatten(1)
    end

    def availability_incompatibilities(package, version)
      @target_platforms.filter_map do |platform|
        next if version_available_on?(package, version, platform)

        marker = marker_package(platform)
        presence = presence_package(package, platform)
        Incompatibility.new(
          [
            Term.new(VersionConstraint.exact(package, version), true),
            Term.new(VersionConstraint.exact(marker, 1), true),
            Term.new(VersionConstraint.exact(presence, 1), true)
          ],
          cause: PlatformAvailability.new(
            package: package,
            version: version,
            platform: platform
          ),
          custom_explanation: "#{package} #{version} is not available on #{platform}"
        )
      end
    end

    def dependency_incompatibilities(package, version)
      dependencies = @packages.fetch(package).fetch(:dependencies).fetch(version)

      dependencies.flat_map do |dependency|
        dependency.platforms.flat_map do |platform|
          next unless version_available_on?(package, version, platform)

          marker = marker_package(platform)
          parent_presence = presence_package(package, platform)
          unless @packages.key?(dependency.package)
            next [unknown_dependency_incompatibility(package, version, dependency, marker, parent_presence, platform)]
          end

          presence = presence_package(dependency.package, platform)
          constraint = parse_dependency(dependency.package, dependency.requirement)
          cause = PlatformDependencyCause.new(
            parent: package,
            version: version,
            dependency: dependency.package,
            platform: platform
          )

          [
            Incompatibility.new(
              [
                Term.new(VersionConstraint.exact(package, version), true),
                Term.new(VersionConstraint.exact(marker, 1), true),
                Term.new(VersionConstraint.exact(parent_presence, 1), true),
                Term.new(VersionConstraint.exact(presence, 1), false)
              ],
              cause: cause,
              custom_explanation: "#{package} #{version} on #{platform} requires #{dependency.package}"
            ),
            Incompatibility.new(
              [
                Term.new(VersionConstraint.exact(package, version), true),
                Term.new(VersionConstraint.exact(marker, 1), true),
                Term.new(VersionConstraint.exact(parent_presence, 1), true),
                Term.new(constraint, false)
              ],
              cause: cause,
              custom_explanation: "#{package} #{version} on #{platform} requires #{dependency.package} #{constraint.range}"
            )
          ]
        end
      end
    end

    def unknown_dependency_incompatibility(package, version, dependency, marker, parent_presence, platform)
      Incompatibility.new(
        [
          Term.new(VersionConstraint.exact(package, version), true),
          Term.new(VersionConstraint.exact(marker, 1), true),
          Term.new(VersionConstraint.exact(parent_presence, 1), true)
        ],
        cause: Incompatibility::InvalidDependency.new(dependency.package, dependency.requirement),
        custom_explanation: "#{package} #{version} on #{platform} depends on unknown package #{dependency.package}"
      )
    end

    def marker_package(platform)
      PlatformMarker.new(platform: platform).tap do |marker|
        raise "missing marker for #{platform}" unless @marker_packages.key?(marker)
      end
    end

    def package_available_on?(package, platform)
      return false unless @packages.key?(package)

      @packages.fetch(package).fetch(:versions).any? do |_version, platforms|
        platforms.include?(platform)
      end
    end

    def version_available_on?(package, version, platform)
      @packages.dig(package, :versions, version)&.include?(platform) == true
    end

    class MultiPlatformSolution
      def self.from_decisions(source, decisions)
        required = source.target_platforms.to_h do |platform|
          marker = source.send(:marker_package, platform)
          next [platform, Set.new] unless decisions.key?(marker)

          packages = decisions.keys.filter_map do |package|
            package.package if source.presence_package?(package) && package.platform == platform
          end
          [platform, packages.to_set]
        end

        common_names = source.target_platforms.map { |platform| required.fetch(platform) }.reduce(:&).to_a.sort
        common = {}
        platform_specific = source.target_platforms.to_h { |platform| [platform, {}] }

        common_names.each do |name|
          common[name] = decisions.fetch(name)
        end

        required.each do |platform, names|
          names.to_a.sort.each do |name|
            next if common_names.include?(name)

            platform_specific[platform][name] = decisions.fetch(name)
          end
        end

        new(common: common, platforms: platform_specific)
      end

      def initialize(common:, platforms:)
        @common = common
        @platforms = platforms
      end

      attr_reader :common, :platforms

      def [](platform)
        @platforms.fetch(platform)
      end

      def to_h
        { common: @common, platforms: @platforms }
      end
    end
  end
end
