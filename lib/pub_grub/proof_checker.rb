require "digest"
require "json"

require_relative "package"
require_relative "rubygems"
require_relative "term"
require_relative "version_constraint"
require_relative "version_range"
require_relative "version_union"

module PubGrub
  class ProofChecker
    PROOF_VERSION = 1

    class InvalidProof < StandardError
    end

    class Result
      attr_reader :root

      def initialize(root:)
        @root = root
      end

      def valid?
        true
      end
    end

    def self.load(path)
      new(JSON.parse(File.read(path)))
    end

    def self.verify(certificate, expected_root_dependencies = nil)
      new(certificate).verify(expected_root_dependencies)
    end

    def self.valid?(certificate, expected_root_dependencies = nil)
      verify(certificate, expected_root_dependencies)
      true
    rescue InvalidProof
      false
    end

    def initialize(certificate)
      @certificate = certificate
    end

    def verify(expected_root_dependencies = nil)
      verify! do
        verify_certificate_digest

        body = proof_body
        @manifest = body.fetch("manifest")
        verify_manifest_digest(body)
        verify_expected_root(expected_root_dependencies)

        @nodes = verify_node_table(body)
        root_id = body.fetch("root")
        @root_id = root_id
        root_node = @nodes[root_id] || invalid!("root references missing derivation")

        @seen = {}
        visit(root_id)

        root_support = root_node.fetch("root_support", [])
        invalid!("root derivation is not a contradiction") unless root_contradiction?(root_node)
        unless root_support.is_a?(Array) && root_support.any?
          invalid!("final contradiction is not rooted in the request")
        end
        root_support.each { |id| visit(id, {}) }
        verify_conflict_root_support(root_node) if root_node.fetch("type") == "conflict"
        invalid!("proof contains unreachable derivations") unless @seen.keys.sort == @nodes.keys.sort

        Result.new(root: root_id)
      end
    end

    def verify_conflict_root_support(node)
      expected = (
        child_root_support(node.fetch("conflict")) +
        child_root_support(node.fetch("other"))
      ).uniq.sort
      invalid!("root support does not follow premises") unless node.fetch("root_support").sort == expected
    end

    private

    def verify!
      yield
    rescue KeyError, ArgumentError, TypeError => error
      raise InvalidProof, error.message
    end

    def root_package?(package)
      package == "root" || Package.root?(package)
    end

    def verify_certificate_digest
      payload = @certificate.fetch("proof")
      digest = @certificate.fetch("payload_digest")
      invalid!("invalid payload digest") unless digest == sha256(payload)
    end

    def proof_body
      body = @certificate.fetch("proof")
      invalid!("unsupported proof version") unless body.fetch("proof_version") == PROOF_VERSION
      body
    end

    def verify_manifest_digest(body)
      digest = body.fetch("manifest_digest")
      invalid!("invalid manifest digest") unless digest == sha256(@manifest)
    end

    def verify_expected_root(expected)
      return unless expected
      actual = @manifest.fetch("root_dependencies")
      invalid!("root dependencies do not match request") unless canonical(expected) == canonical(actual)
    end

    def verify_node_table(body)
      nodes = body.fetch("nodes")
      invalid!("nodes must be an array") unless nodes.is_a?(Array)

      nodes.each_with_object({}) do |node, table|
        invalid!("node must be an object") unless node.is_a?(Hash)
        id = node.fetch("id")
        payload = node.reject { |key, _| key == "id" }
        invalid!("derivation id mismatch") unless id.is_a?(String) && id == sha256(payload)
        invalid!("duplicate derivation id") if table.key?(id)
        table[id] = node
      end
    end

    def visit(id, visiting = {}, &block)
      node = @nodes[id] || invalid!("missing derivation #{id}")
      return @seen[id] if @seen[id]
      invalid!("cyclic derivation graph") if visiting[id]

      visiting[id] = true
      verify_node(node) { |child_id| visit(child_id, visiting, &block) }
      visiting.delete(id)

      @seen[id] = node
      block&.call(node)
      node
    end

    def verify_node(node)
      case node.fetch("type")
      when "external"
        verify_external_node(node)
      when "conflict"
        verify_conflict_node(node) { |child_id| yield(child_id) }
      else
        invalid!("unknown derivation type")
      end
    end

    def verify_external_node(node)
      terms = parse_terms(node.fetch("terms"))
      cause = node.fetch("cause")
      verify_external_root_support(node, terms, cause)

      case cause.fetch("type")
      when "root"
        invalid!("invalid root premise") unless terms.length == 1 && negative_root_any?(terms[0])
      when "dependency"
        if terms.any? { |term| root_package?(term.package) }
          verify_request_premise(terms)
        else
          verify_dependency_premise(terms)
        end
      when "request"
        verify_request_premise(terms)
      when "no_versions"
        verify_no_versions_premise(terms, cause)
      when "invalid_dependency"
        verify_invalid_dependency_premise(terms, cause)
      else
        invalid!("unknown external premise")
      end
    end

    def verify_external_root_support(node, terms, cause)
      support = node.fetch("root_support", [])
      invalid!("root support must be an array") unless support.is_a?(Array)
      return if root_contradiction?(node)
      invalid!("external premise cannot declare derived root support") if support.length > 1

      expected =
        if cause.fetch("type") == "request"
          []
        elsif terms.length == 2 && terms.any?(&:positive?) && terms.any?(&:negative?)
          positive = terms.find(&:positive?)
          negative_term = terms.find(&:negative?)
          if root_package?(positive.package)
            invalid!("root support must identify the root request premise") unless support.length == 1
            request = @nodes[support.first]
            request_terms = request && parse_terms(request.fetch("terms"))
            requested = request_terms&.find(&:negative?)
            valid = request&.dig("cause", "type") == "request" && requested&.eql?(negative_term)
            invalid!("root support does not match this premise") unless valid
            support
          elsif support.any?
            support_id = support.first
            request = @nodes[support_id]
            invalid!("root support premise is missing") unless request
            request_terms = parse_terms(request.fetch("terms"))
            requested = request_terms.find(&:negative?)
            valid_request = request.fetch("cause").fetch("type") == "request" &&
              requested&.package == positive.package &&
              positive.constraint.range.intersects?(requested.constraint.range)
            invalid!("root support does not match this premise") unless valid_request
            support
          else
            []
          end
        else
          []
        end

      invalid!("root support does not match this premise") unless support.sort == expected.sort
    end

    def verify_conflict_node(node)
      conflict_id = node.fetch("conflict")
      other_id = node.fetch("other")
      is_root = node.equal?(@nodes.fetch(@root_id, nil))
      invalid!("conflict requires two distinct premises") unless conflict_id != other_id
      root_support = node.fetch("root_support")
      invalid!("root support must be an array") unless root_support.is_a?(Array)

      yield(conflict_id)
      yield(other_id)

      expected_root_support = (
        child_root_support(conflict_id) + child_root_support(other_id)
      ).uniq.sort
      unless (is_root && root_support.empty?) || root_support.sort == expected_root_support
        invalid!("root support does not follow premises")
      end
      conflict_terms = parse_terms(@nodes.fetch(conflict_id).fetch("terms"))
      other_terms = parse_terms(@nodes.fetch(other_id).fetch("terms"))
      result_terms = parse_terms(node.fetch("terms"))
      most_recent = parse_term(node.fetch("most_recent_term"))
      resolution = parse_term(node.fetch("resolution_term"))
      package = most_recent.package

      unless conflict_terms.any? { |term| term.eql?(most_recent) }
        invalid!("most recent term is not a premise")
      end

      resolved = other_terms.find { |term| term.package == package }
      invalid!("resolution package is not present in premise") unless resolved
      unless terms_conflict?(resolution, resolved) || resolution.satisfies?(most_recent)
        invalid!("resolution term does not match a local conflict merge")
      end
      invalid!("resolution term package mismatch") unless resolution.package == package

      expected = conflict_terms.reject { |term| term.eql?(most_recent) }
      expected.concat(other_terms.reject { |term| term.package == package })
      difference = resolution.difference(most_recent)
      expected << difference.invert unless difference.empty?
      expected = cleanup_derived_terms(expected)

      unless term_sets_equal?(expected, result_terms)
        invalid!("conflict merge produced different terms")
      end
      invalid!("root support premise is missing") unless root_support.all? { |id| @nodes[id] && root_dependency_premise?(@nodes.fetch(id)) }
    end

    def child_root_support(id)
      node = @nodes.fetch(id)
      node.fetch("root_support", [])
    end

    def terms_conflict?(left, right)
      left.package == right.package && left.satisfies?(right.invert)
    end

    def verify_dependency_premise(terms)
      invalid!("dependency premise must have two terms") unless terms.length == 2
      positive_terms = terms.select(&:positive?)
      dependency_term = terms.find(&:negative?)
      invalid!("dependency premise has invalid polarity") unless positive_terms.one? && dependency_term

      source_term = positive_terms[0]
      package = source_term.package
      dependencies = maximal_dependency_map(package, source_term)
      requirement = dependencies && dependencies.fetch(dependency_term.package.to_s, nil)

      invalid!("dependency premise is absent from frozen manifest for #{package}") unless requirement
      parsed = parse_requirement(dependency_term.package, requirement)
      expected = Term.new(VersionConstraint.new(dependency_term.package, range: parsed), false)
      invalid!("dependency range does not match original requirement") unless expected.eql?(dependency_term)
    end

    def verify_request_premise(terms)
      invalid!("request premise must have two terms") unless terms.length == 2
      root_term = terms.find { |term| term.positive? && root_package?(term.package) && term.constraint.range.any? }
      requested = terms.find(&:negative?)
      invalid!("request premise has invalid terms") unless root_term && requested

      requirement = manifest_root_requirement(requested.package.to_s)
      invalid!("request is absent from frozen manifest") unless requirement
      parsed = parse_requirement(requested.package, requirement)
      expected = Term.new(VersionConstraint.new(requested.package, range: parsed), false)
      invalid!("request range does not match original request") unless expected.eql?(requested)
    end

    def verify_no_versions_premise(terms, cause)
      invalid!("no-versions premise must have one term") unless terms.length == 1
      term = terms[0]
      invalid!("no-versions term must be positive") unless term.positive?
      invalid!("no-versions cannot apply to root") if root_package?(term.package)

      caused_term = parse_term(cause.fetch("constraint"))
      invalid!("no-versions cause does not match term") unless caused_term.eql?(term)
      invalid!("frozen manifest contains matching versions") unless matching_versions(term).empty?
    end

    def verify_invalid_dependency_premise(terms, cause)
      invalid!("invalid-dependency premise must have one term") unless terms.length == 1
      term = terms[0]
      invalid!("invalid-dependency term must be positive") unless term.positive?
      invalid!("invalid-dependency cannot apply to root") if root_package?(term.package)

      requirement = cause.fetch("requirement")
      dependency_map = maximal_dependency_map(term.package, term)
      invalid!("invalid-dependency requirement mismatch") unless dependency_map && dependency_map[cause.fetch("package")] == requirement
      invalid!("package is present in frozen manifest") if manifest_package(cause.fetch("package"))
    end

    def root_dependency_premise?(node)
      return false unless node.fetch("type") == "external"
      cause = node.fetch("cause").fetch("type")
      cause == "request" ||
        (cause == "dependency" && parse_terms(node.fetch("terms")).any? { |term| root_package?(term.package) })
    end


    def root_contradiction?(node)
      terms = parse_terms(node.fetch("terms"))
      terms.empty? ||
        (terms.length == 1 && terms[0].positive? && root_package?(terms[0].package) && terms[0].constraint.range.any?)
    end

    def negative_root_any?(term)
      !term.positive? && root_package?(term.package) && term.constraint.range.any?
    end

    def manifest_root_requirement(package)
      root_dependencies = @manifest.fetch("root_dependencies")
      root_dependencies.fetch(package, nil)
    end

    def maximal_dependency_map(package, source_term)
      package_manifest = manifest_package(package.to_s)
      return nil unless package_manifest

      versions = package_versions(package.to_s)
      selected = versions.select { |version| source_term.constraint.range.include?(version) }
      return nil if selected.empty?

      dependencies = selected.map do |version|
        package_manifest.fetch("dependencies").fetch(version.to_s)
      end.uniq

      invalid!("premise range combines different original dependencies") unless dependencies.length == 1
      verify_maximal_bound(package.to_s, versions, selected, dependencies.first)
      dependencies.first
    end

    def verify_maximal_bound(name, all_versions, selected, requirement)
      lower_index = all_versions.index(selected.first)
      upper_index = all_versions.index(selected.last)
      lower_allowed = lower_index.zero? || dependency_at(name, all_versions[lower_index - 1]) != requirement
      upper_allowed = upper_index == all_versions.length - 1 || dependency_at(name, all_versions[upper_index + 1]) != requirement
      invalid!("dependency premise range is not maximal") unless lower_allowed && upper_allowed
    end

    def dependency_at(name, version)
      manifest_package(name).fetch("dependencies").fetch(version.to_s)
    end

    def matching_versions(term)
      package_manifest = manifest_package(term.package.to_s)
      return [] unless package_manifest
      package_versions(term.package.to_s).select do |version|
        term.constraint.range.include?(version)
      end
    end

    def package_versions(name)
      manifest_package(name).fetch("versions").map do |version|
        Gem::Version.new(version)
      end.sort
    end

    def manifest_package(name)
      @manifest.fetch("package_versions").fetch(name, nil)
    end

    def parse_requirement(package, requirement)
      RubyGems.requirement_to_range(Gem::Requirement.new(Array(requirement))).tap do |range|
        invalid!("unsupported requirement range") unless range.is_a?(VersionRange)
      end
    rescue ArgumentError
      invalid!("invalid original dependency requirement")
    end

    def parse_terms(value)
      invalid!("terms must be an array") unless value.is_a?(Array)
      value.map { |item| parse_term(item) }
    end

    def parse_term(value)
      invalid!("term must be an object") unless value.is_a?(Hash)
      package = value.fetch("package")
      positive = value.fetch("positive")
      invalid!("term polarity must be boolean") unless positive == true || positive == false
      Term.new(VersionConstraint.new(package, range: parse_range(value.fetch("range"))), positive)
    end

    def parse_range(value)
      invalid!("range must be an object") unless value.is_a?(Hash)
      case value.fetch("type")
      when "any"
        VersionRange.any
      when "empty"
        VersionRange.empty
      when "range"
        VersionRange.new(
          min: parse_bound(value["min"]),
          max: parse_bound(value["max"]),
          include_min: value.fetch("include_min"),
          include_max: value.fetch("include_max")
        )
      when "union"
        ranges = value.fetch("ranges").map { |item| parse_range(item) }
        VersionUnion.union(ranges)
      else
        invalid!("unknown range type")
      end
    rescue ArgumentError => error
      invalid!(error.message)
    end

    def parse_bound(value)
      return nil if value.nil?
      invalid!("version bound must be a string") unless value.is_a?(String)
      Gem::Version.new(value)
    end

    def cleanup_derived_terms(terms)
      terms = terms.reject do |term|
        terms.length != 1 && term.positive? && root_package?(term.package)
      end
      terms.group_by(&:package).map do |_, package_terms|
        package_terms.inject(&:intersect)
      end
    end

    def term_sets_equal?(left, right)
      left.map { |term| serialize_term(term) }.sort_by(&:to_s) ==
        right.map { |term| serialize_term(term) }.sort_by(&:to_s)
    end

    def serialize_term(term)
      {
        "package" => term.package.to_s,
        "positive" => term.positive?,
        "range" => term.constraint.range
      }
    end

    def canonical(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, result| result[key.to_s] = canonical(value[key]) }
      when Array
        value.map { |item| canonical(item) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    def sha256(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def invalid!(message)
      raise InvalidProof, message
    end
  end
end
