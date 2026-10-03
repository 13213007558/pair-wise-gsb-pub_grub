# frozen_string_literal: true

require "rubygems"

module PubGrub
  class ProviderVersion < ::Gem::Version
    attr_reader :capability_version, :package, :version, :preference

    def self.for(capability_version:, package:, version:, preference: 0)
      allocate.tap do |provider_version|
        provider_version.send(:build, capability_version, package, version, preference)
      end
    end

    def <=>(other)
      return super unless other.is_a?(ProviderVersion)

      comparison = capability_version <=> other.capability_version
      return comparison unless comparison.zero?

      comparison = preference <=> other.preference
      return comparison unless comparison.zero?

      comparison = package.to_s <=> other.package.to_s
      return comparison unless comparison.zero?

      version <=> other.version
    end

    def hash
      [capability_version, package, version, preference].hash
    end

    def eql?(other)
      other.is_a?(ProviderVersion) &&
        capability_version.eql?(other.capability_version) &&
        package.eql?(other.package) &&
        version.eql?(other.version) &&
        preference.eql?(other.preference)
    end

    alias == eql?

    def to_s
      capability_version.to_s
    end

    alias inspect to_s

    private

    def build(capability_version, package, provider_version, preference)
      @capability_version = as_base_version(capability_version)
      initialize(@capability_version.to_s)
      @package = package
      @version = as_base_version(provider_version)
      @preference = preference
    end

    def as_base_version(value)
      return value if value.is_a?(ProviderVersion)
      value.is_a?(::Gem::Version) ? value : ::Gem::Version.new(value)
    end
  end
end
