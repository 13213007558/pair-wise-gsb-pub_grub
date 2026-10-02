# frozen_string_literal: true

module PubGrub
  class FeatureDependency
    attr_reader :constraint, :features, :default_features

    def initialize(constraint = nil, features: [], default_features: true)
      @constraint = constraint || ">= 0"
      @features = Array(features).dup
      @default_features = default_features
    end

    def hash
      [constraint, features, default_features].hash
    end

    def ==(other)
      other.is_a?(self.class) &&
        constraint == other.constraint &&
        features == other.features &&
        default_features == other.default_features
    end
    alias_method :eql?, :==

    def to_s
      parts = [constraint.inspect]
      parts << "features: #{features.inspect}" unless features.empty?
      parts << "default_features: #{default_features.inspect}" unless default_features
      "#{self.class.name.sub('PubGrub::', '')}(#{parts.join(', ')})"
    end

    def inspect
      "#<#{self.class} #{self}>"
    end

    def self.coerce(dependency)
      case dependency
      when self
        dependency
      when Hash
        new(
          dependency[:version] || dependency[:requirement] || dependency[:constraint],
          features: dependency[:features] || [],
          default_features: dependency.fetch(:default_features, true)
        )
      else
        new(dependency)
      end
    end

    def self.feature_dependency?(dependency)
      dependency.is_a?(self)
    end
  end
end
