# frozen_string_literal: true

module PubGrub
  class FeaturePackage
    attr_reader :package, :feature

    def initialize(package, feature)
      @package = package
      @feature = feature
    end

    def self.feature?(package)
      package.is_a?(self)
    end

    def root?
      false
    end

    def hash
      [package, feature].hash
    end

    def ==(other)
      other.is_a?(self.class) &&
        package == other.package &&
        feature == other.feature
    end
    alias_method :eql?, :==

    def to_s
      "#{package}[#{feature}]"
    end

    def inspect
      "#<#{self.class} #{self}>"
    end
  end
end
