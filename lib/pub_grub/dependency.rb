module PubGrub
  # A dependency one package has on another: a version constraint plus
  # optional feature requests (similar to Cargo features).
  #
  # * +constraint+ is the user-defined version requirement (e.g. a
  #   String like ">= 1.0", an Array of requirements, or a
  #   Gem::Requirement)
  # * +features+ is a list of feature names requested on the dependency
  # * +default_features?+ is whether the dependency's default features
  #   are requested. Default features are enabled for a package when
  #   _any_ incoming edge requests them.
  class Dependency
    attr_reader :constraint, :features

    def initialize(constraint, features: [], default_features: true)
      @constraint = constraint
      @features = features.map(&:to_s).freeze
      @default_features = default_features ? true : false
    end

    def default_features?
      @default_features
    end

    # Normalize a user-supplied dependency specification.
    #
    # Accepts a plain constraint (">= 1.0", Gem::Requirement, ...), a
    # Hash with :constraint/:features/:default_features keys, or an
    # existing Dependency.
    def self.coerce(value)
      case value
      when Dependency
        value
      when Hash
        constraint = value[:constraint] || value['constraint'] || '>= 0'
        features = value[:features] || value['features'] || []
        default_features =
          if value.key?(:default_features)
            value[:default_features]
          elsif value.key?('default_features')
            value['default_features']
          else
            true
          end
        new(constraint, features: features, default_features: default_features)
      else
        new(value)
      end
    end

    def ==(other)
      other.is_a?(Dependency) &&
        constraint == other.constraint &&
        features == other.features &&
        default_features? == other.default_features?
    end
    alias_method :eql?, :==

    def hash
      constraint.hash ^ features.hash ^ default_features?.hash
    end

    def inspect
      parts = [constraint.inspect]
      parts << "features: #{features.inspect}" unless features.empty?
      parts << "default_features: false" unless default_features?
      "#<#{self.class} #{parts.join(', ')}>"
    end
  end
end
