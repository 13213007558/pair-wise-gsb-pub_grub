# frozen_string_literal: true

module PubGrub
  # Result of a joint multi-platform solve.
  #
  # Packages needed on every target platform with one shared version live in
  # #common; packages needed by only a subset of platforms live in #only_on,
  # keyed by platform. Platform-specific packages of the same name always carry
  # the same version whenever they appear on more than one platform.
  class MultiPlatformSolution
    # @return [Array<Symbol>] target platforms, in declaration order
    attr_reader :platforms

    # @return [Hash{String => Gem::Version}] packages required on every
    #   platform, with the single shared version
    attr_reader :common

    # @return [Hash{Symbol => Hash{String => Gem::Version}}}] packages only
    #   required on a given platform
    attr_reader :only_on

    def initialize(platforms, common, only_on)
      @platforms = platforms
      @common = common
      @only_on = only_on
    end

    # Full set of packages selected for one platform, shared + platform-only.
    def for_platform(platform)
      platform = platform.to_sym
      common.merge(only_on.fetch(platform, {}))
    end

    # Every (platform, package, version) row, useful when writing a lockfile
    # that records which platforms each entry applies to.
    def entries
      rows = common.map { |name, version| [name, version, platforms.dup] }

      only_on.each do |platform, deps|
        deps.each do |name, version|
          rows << [name, version, [platform]]
        end
      end

      rows
    end

    def to_h
      {
        platforms: platforms,
        common: common,
        only_on: only_on
      }
    end

    def ==(other)
      other.is_a?(MultiPlatformSolution) && to_h == other.to_h
    end

    def inspect
      "#<#{self.class} platforms=#{platforms.inspect} common=#{common.size} " \
        "only_on=#{only_on.values.sum(&:size)}>"
    end
  end
end
