# frozen_string_literal: true

module PubGrub
  # The version of a capability (virtual package), as provided by a concrete
  # package.
  #
  # Capability versions are independent from the providing package's own
  # versions: depending on "image-reader >= 2.0" constrains the capability,
  # not any particular provider.
  #
  # Each provider gets its own distinct CapabilityVersion, so choosing a
  # provider is an ordinary version choice the solver can backtrack over.
  class CapabilityVersion < Gem::Version
    attr_reader :provider

    # Gem::Version overrides .new with a single-argument caching factory,
    # so the two-argument constructor is defined explicitly here.
    def self.new(version, provider)
      obj = allocate
      obj.send(:initialize, version, provider)
      obj
    end

    def initialize(version, provider)
      @provider = provider
      super(version.to_s)
    end

    # Compares numerically against plain versions. When two providers offer
    # the same capability version, the provider breaks the tie so that each
    # CapabilityVersion stays distinct and totally ordered.
    def <=>(other)
      if CapabilityVersion === other
        cmp = super
        cmp.zero? ? provider.to_s <=> other.provider.to_s : cmp
      else
        super
      end
    end

    def ==(other)
      CapabilityVersion === other && super && provider == other.provider
    end

    def eql?(other)
      self == other
    end

    def hash
      [super, provider].hash
    end

    # The capability version as a plain Gem::Version, without the provider.
    def capability_version
      Gem::Version.new(version)
    end

    def to_s
      "#{version} (provided by #{provider})"
    end
  end
end
