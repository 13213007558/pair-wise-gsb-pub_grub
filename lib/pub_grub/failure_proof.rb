require "digest"
require "json"

require_relative "incompatibility"
require_relative "package"
require_relative "term"
require_relative "version_constraint"
require_relative "version_range"
require_relative "version_union"

module PubGrub
  class FailureProof
    PROOF_VERSION = 1

    def self.build(incompatibility, source:)
      new(incompatibility, source).build
    end

    def initialize(incompatibility, source)
      @incompatibility = incompatibility
      @source = source
      @nodes = {}
      @object_nodes = {}
      @object_ids = {}
      @object_support_ids = {}
      @root_support = {}
      @request_premises = {}
      @objects = []
    end

    def build
      manifest = build_manifest
      root_object_id = register_incompatibility(@incompatibility)
      build_node_table
      root_id = @object_ids.fetch(root_object_id)

      body = {
        "proof_version" => PROOF_VERSION,
        "manifest_digest" => digest(canonical(manifest)),
        "manifest" => manifest,
        "root" => root_id,
        "nodes" => @nodes.keys.sort.map { |id| @nodes[id] }
      }

      {
        "certificate_version" => PROOF_VERSION,
        "payload_digest" => digest(canonical(body)),
        "proof" => body
      }
    end

    def to_json
      JSON.pretty_generate(build)
    end

    private

    def build_manifest
      packages = {}

      @incompatibility.external_incompatibilities.uniq.each do |incompatibility|
        incompatibility.terms.each do |term|
          add_manifest_package(packages, term.package) unless Package.root?(term.package)
        end

        if Incompatibility::InvalidDependency === incompatibility.cause
          add_manifest_package(packages, incompatibility.cause.package)
        end
      end

      {
        "root_dependencies" => canonical_dependency_map(@source.root_dependencies),
        "package_versions" => packages.sort.to_h
      }
    end

    def add_manifest_package(packages, package)
      id = package_id(package)
      return if packages.key?(id)

      versions = @source.all_versions_for(package).sort
      packages[id] = {
        "versions" => versions.map { |version| version_id(version) },
        "dependencies" => versions.map do |version|
          [
            version_id(version),
            canonical_dependency_map(@source.dependencies_for(package, version))
          ]
        end.to_h
      }
    rescue StandardError
      packages[id] = nil
    end

    def canonical_dependency_map(dependencies)
      dependencies.map do |package, requirement|
        [package_id(package), serialize_requirement(requirement)]
      end.sort.to_h
    end

    def serialize_requirement(requirement)
      if @source.respond_to?(:serialize_proof_requirement)
        requirement = @source.serialize_proof_requirement(requirement)
      end

      case requirement
      when Array
        requirement.map { |item| String(item) }
      when String, Symbol, Numeric
        String(requirement)
      else
        raise ArgumentError, "cannot serialize dependency requirement #{requirement.inspect}"
      end
    end

    def register_incompatibility(incompatibility)
      unless @object_nodes.key?(incompatibility.object_id)
        @object_nodes[incompatibility.object_id] = incompatibility
        @object_ids[incompatibility.object_id] = nil
        @objects << incompatibility
      end
      incompatibility.object_id
    end

    def build_node_table
      ordered_objects = []
      visited = {}
      visit_for_serialization = lambda do |incompatibility|
        return if visited[incompatibility.object_id]
        visited[incompatibility.object_id] = true
        if incompatibility.conflict?
          visit_for_serialization.call(incompatibility.cause.conflict)
          visit_for_serialization.call(incompatibility.cause.other)
        end
        root_support_ids(incompatibility).each do |object_id|
          visit_for_serialization.call(@object_nodes.fetch(object_id))
        end
        ordered_objects << incompatibility
      end
      visit_for_serialization.call(@incompatibility)

      ordered_objects.each do |incompatibility|
        support = root_support_ids(incompatibility).map { |object_id| @object_ids.fetch(object_id) }
        @object_support_ids[incompatibility.object_id] = support
        payload = node_payload(incompatibility)
        id = digest(canonical(payload))
        @object_nodes[incompatibility.object_id] = id
        @object_ids[incompatibility.object_id] = id
        @nodes[id] = { "id" => id }.merge(payload)
      end
    end

    def node_payload(incompatibility)
      if incompatibility.conflict?
        cause = incompatibility.cause
        {
          "type" => "conflict",
          "terms" => incompatibility.terms.map { |term| serialize_term(term) },
          "conflict" => @object_ids.fetch(register_incompatibility(cause.conflict)),
          "other" => @object_ids.fetch(register_incompatibility(cause.other)),
          "root_support" => @object_support_ids.fetch(incompatibility.object_id, []),
          "most_recent_term" => serialize_term(cause.most_recent_term),
          "resolution_term" => serialize_term(cause.resolution_term)
        }
      else
        {
          "type" => "external",
          "cause" => serialize_cause(incompatibility.cause),
          "terms" => incompatibility.terms.map { |term| serialize_term(term) },
          "root_support" => @object_support_ids.fetch(incompatibility.object_id, [])
        }
      end
    end

    def root_support_ids(incompatibility)
      @root_support[incompatibility.object_id] ||=
        if incompatibility.conflict?
          cause = incompatibility.cause
          [
            root_support_ids(cause.conflict),
            root_support_ids(cause.other)
          ].flatten.uniq.sort
        elsif incompatibility.cause == :dependency
          dependency_root_support(incompatibility)
        else
          []
        end
    end

    def dependency_root_support(incompatibility)
      source_term = incompatibility.terms.find(&:positive?)
      return [] unless source_term
      if Package.root?(source_term.package)
        negative_term = incompatibility.terms.find(&:negative?)
        return [] unless negative_term
        return [request_premise_id(negative_term.package, negative_term.constraint.range)]
      end

      requirement = @source.root_dependencies.find do |package, _|
        package_id(package) == source_term.package
      end
      return [] unless requirement

      root_package, raw_requirement = requirement
      root_constraint = @source.parse_dependency(root_package, raw_requirement)
      return [] unless root_constraint.is_a?(VersionConstraint)
      return [] unless source_term.constraint.allows_any?(root_constraint)

      [request_premise_id(source_term.package, root_constraint.range)]
    end

    def request_premise_id(package, range)
      key = [package, range]
      @request_premises[key] ||= begin
        premise = Incompatibility.new([
          Term.new(VersionConstraint.any(Package.root), true),
          Term.new(VersionConstraint.new(package, range: range), false)
        ], cause: :request)
        object_id = premise.object_id
        unless @object_nodes.key?(object_id)
          @object_nodes[object_id] = premise
          @object_ids[object_id] = nil
          @objects << premise
        end
        object_id
      end
    end

    def serialize_cause(cause)
      case cause
      when :root
        { "type" => "root" }
      when :dependency
        { "type" => "dependency" }
      when :request
        { "type" => "request" }
      when Incompatibility::InvalidDependency
        {
          "type" => "invalid_dependency",
          "package" => package_id(cause.package),
          "requirement" => serialize_requirement(cause.constraint)
        }
      when Incompatibility::NoVersions
        {
          "type" => "no_versions",
          "constraint" => serialize_term(cause.constraint)
        }
      else
        raise ArgumentError, "unsupported proof cause: #{cause.inspect}"
      end
    end

    def serialize_term(term)
      {
        "package" => package_id(term.package),
        "positive" => term.positive?,
        "range" => serialize_range(term.constraint.range)
      }
    end

    def serialize_range(range)
      case range
      when VersionRange
        if range.empty?
          { "type" => "empty" }
        elsif range.any?
          { "type" => "any" }
        else
          {
            "type" => "range",
            "min" => range.min && version_id(range.min),
            "max" => range.max && version_id(range.max),
            "include_min" => range.include_min?,
            "include_max" => range.include_max?
          }
        end
      when VersionUnion
        {
          "type" => "union",
          "ranges" => range.ranges.map { |item| serialize_range(item) }
        }
      else
        raise ArgumentError, "unsupported proof range: #{range.inspect}"
      end
    end

    def package_id(package)
      if @source.respond_to?(:proof_package_id)
        @source.proof_package_id(package)
      elsif Package.root?(package)
        "root"
      else
        String(package)
      end
    end

    def version_id(version)
      if @source.respond_to?(:serialize_proof_version)
        @source.serialize_proof_version(version)
      else
        String(version)
      end
    end

    def canonical(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) do |key, result|
          result[String(key)] = canonical(value[key])
        end
      when Array
        value.map { |item| canonical(item) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(value))
    end
  end
end
