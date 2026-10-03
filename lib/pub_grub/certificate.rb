require 'json'
require 'digest'

require_relative 'incompatibility'
require_relative 'term'
require_relative 'version_constraint'
require_relative 'version_range'
require_relative 'version_union'
require_relative 'package'

module PubGrub
  # A machine-readable proof that version solving failed.
  #
  # A certificate bundles three things:
  #
  # 1. A frozen manifest of every package version (and its original
  #    dependencies) that the failed derivation depends on.
  # 2. The derivation DAG of incompatibilities, from external facts
  #    (root request, dependencies, missing versions) through every
  #    conflict-merge step.
  # 3. The conclusion: the final incompatibility showing the root
  #    request itself cannot be satisfied.
  #
  # Certificates are verified independently by CertificateChecker, which
  # only replays the individual derivation steps and never re-runs the
  # solver.
  class Certificate
    FORMAT = "pub_grub/unsat-certificate@1"

    ROOT_VERSION_STRING = "0"

    attr_reader :manifest, :incompatibilities, :conclusion

    def initialize(manifest:, incompatibilities:, conclusion:, claimed_manifest_sha256: nil)
      @manifest = manifest
      @incompatibilities = incompatibilities
      @conclusion = conclusion
      @claimed_manifest_sha256 = claimed_manifest_sha256
    end

    # Build a certificate for a failed solve.
    #
    # +failure+ is the final (failure) Incompatibility carried by
    # SolveFailure, +source+ quacks like BasicPackageSource and is used
    # to freeze the relevant package manifest.
    def self.build(failure, source)
      nodes = []
      ids = {}.compare_by_identity
      packages = []

      visit = lambda do |incompatibility|
        return ids[incompatibility] if ids.key?(incompatibility)

        cause =
          case incompatibility.cause
          when :root
            { "type" => "root" }
          when :dependency
            { "type" => "dependency" }
          when Incompatibility::NoVersions
            { "type" => "no_versions" }
          when Incompatibility::InvalidDependency
            {
              "type" => "invalid_dependency",
              "dep_package" => incompatibility.cause.package.to_s
            }
          when Incompatibility::ConflictCause
            {
              "type" => "conflict",
              "prior" => [
                visit.call(incompatibility.cause.conflict),
                visit.call(incompatibility.cause.other)
              ]
            }
          else
            raise ArgumentError, "cannot certify incompatibility cause: #{incompatibility.cause.inspect}"
          end

        terms = incompatibility.terms.map do |term|
          unless Package.root?(term.package)
            packages << term.package unless packages.include?(term.package)
          end
          serialize_term(term)
        end

        ids[incompatibility] = nodes.length
        nodes << {
          "id" => nodes.length,
          "terms" => terms,
          "cause" => cause
        }
        ids[incompatibility]
      end

      conclusion = visit.call(failure)

      new(
        manifest: freeze_manifest(source, packages),
        incompatibilities: nodes,
        conclusion: conclusion
      )
    end

    # Load a certificate from a JSON string or an already-parsed Hash.
    def self.load(payload)
      hash = payload.is_a?(String) ? JSON.parse(payload) : payload
      unless hash.is_a?(Hash)
        raise ArgumentError, "certificate must be a JSON object"
      end

      new(
        manifest: hash["manifest"],
        incompatibilities: hash["incompatibilities"],
        conclusion: hash["conclusion"],
        claimed_manifest_sha256: hash["manifest_sha256"]
      )
    end

    def self.load_file(path)
      load(File.read(path))
    end

    # The digest recorded in the certificate itself. For freshly built
    # certificates this always matches #manifest_sha256; a loaded
    # certificate may carry a digest that does not (tampering), which
    # the CertificateChecker rejects.
    def claimed_manifest_sha256
      @claimed_manifest_sha256 || manifest_sha256
    end

    def manifest_sha256
      Digest::SHA256.hexdigest(self.class.canonical_json(manifest))
    end

    def to_h
      {
        "format" => FORMAT,
        "manifest_sha256" => manifest_sha256,
        "manifest" => manifest,
        "incompatibilities" => incompatibilities,
        "conclusion" => conclusion
      }
    end

    def to_json(*args)
      to_h.to_json(*args)
    end

    # Deterministic JSON: hash keys are sorted recursively, array order
    # is preserved (the frozen version list is significant).
    def self.canonical_json(object)
      case object
      when Hash
        "{" + object.keys.map(&:to_s).sort.map { |key|
          "#{key.to_json}:#{canonical_json(object[key] || object[key.to_sym])}"
        }.join(",") + "}"
      when Array
        "[" + object.map { |element| canonical_json(element) }.join(",") + "]"
      else
        object.to_json
      end
    end

    class << self
      # Freeze the versions and original dependencies of every package
      # the derivation touches, plus the root request itself.
      def freeze_manifest(source, packages)
        frozen = {
          "root" => freeze_entry(ROOT_VERSION_STRING, source.root_dependencies)
        }

        packages.map(&:to_s).sort.each do |name|
          package = packages.find { |p| p.to_s == name }
          versions = source.all_versions_for(package).sort
          deps = {}
          versions.each do |version|
            deps[version.to_s] = serialize_dependencies(source.dependencies_for(package, version))
          end
          frozen["packages"] ||= {}
          frozen["packages"][name] = {
            "versions" => versions.map(&:to_s),
            "deps" => deps
          }
        end

        frozen["packages"] ||= {}
        frozen
      end

      def freeze_entry(version, dependencies)
        {
          "versions" => [version],
          "deps" => { version => serialize_dependencies(dependencies) }
        }
      end

      def serialize_dependencies(dependencies)
        dependencies.to_h do |package, requirement|
          [package.to_s, serialize_requirement(requirement)]
        end
      end

      def serialize_requirement(requirement)
        case requirement
        when String
          requirement
        when Array
          requirement.map(&:to_s)
        else
          requirement.to_s
        end
      end

      def serialize_term(term)
        json = {
          "positive" => term.positive?,
          "range" => serialize_range(term.constraint.range)
        }
        if Package.root?(term.package)
          json["root"] = true
        else
          json["package"] = term.package.to_s
        end
        json
      end

      def serialize_range(range)
        if range.is_a?(VersionUnion)
          {
            "type" => "union",
            "ranges" => range.ranges.map { |r| serialize_simple_range(r) }
          }
        elsif range.empty?
          { "type" => "empty" }
        elsif range.any?
          { "type" => "any" }
        else
          serialize_simple_range(range)
        end
      end

      def serialize_simple_range(range)
        {
          "type" => "range",
          "min" => range.min&.to_s,
          "max" => range.max&.to_s,
          "include_min" => range.include_min?,
          "include_max" => range.include_max?
        }
      end

      def parse_term(json)
        package = json["root"] ? Package.root : json["package"]
        constraint = VersionConstraint.new(package, range: parse_range(json["range"]))
        Term.new(constraint, json["positive"])
      end

      def parse_range(json)
        case json["type"]
        when "empty"
          VersionRange.empty
        when "any"
          VersionRange.any
        when "range"
          VersionRange.new(
            min: json["min"] && Gem::Version.new(json["min"]),
            max: json["max"] && Gem::Version.new(json["max"]),
            include_min: json["include_min"],
            include_max: json["include_max"]
          )
        when "union"
          VersionUnion.union(json["ranges"].map { |r| parse_range(r) })
        else
          raise ArgumentError, "unknown range type: #{json["type"].inspect}"
        end
      end
    end
  end
end
