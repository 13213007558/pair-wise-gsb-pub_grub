require_relative 'certificate'
require_relative 'incompatibility'
require_relative 'rubygems'
require_relative 'term'
require_relative 'version_constraint'
require_relative 'version_range'

module PubGrub
  # Independently verifies a Certificate produced for a failed solve.
  #
  # The checker only replays the individual, local derivation steps:
  #
  # * the frozen manifest matches its recorded SHA-256 digest
  # * every dependency / no-versions / invalid-dependency
  #   incompatibility follows from the frozen manifest and its
  #   original dependencies
  # * every conflict step is a valid merge of its two premises
  # * the conclusion is a genuine contradiction whose derivation
  #   reaches the root request
  #
  # It never re-runs the solver or any search.
  class CertificateChecker
    class Invalid < StandardError; end

    def initialize(certificate, manifest_sha256: nil)
      @certificate =
        case certificate
        when Certificate then certificate
        else Certificate.load(certificate)
        end
      @pinned_manifest_sha256 = manifest_sha256
    end

    def self.verify(certificate, **options)
      new(certificate, **options).verify
    end

    def self.verify_file(path, **options)
      verify(Certificate.load_file(path), **options)
    end

    # Returns true when the certificate is valid, raises
    # CertificateChecker::Invalid describing the problem otherwise.
    def verify
      check_manifest!
      check_incompatibilities!
      check_conclusion!
      true
    end

    private

    def check_manifest!
      if @pinned_manifest_sha256 && @pinned_manifest_sha256 != @certificate.manifest_sha256
        raise Invalid, "manifest does not match the pinned sha256 digest"
      end

      if @certificate.claimed_manifest_sha256 != @certificate.manifest_sha256
        raise Invalid, "manifest does not match its recorded sha256 digest"
      end

      manifest = @certificate.manifest
      raise Invalid, "certificate has no manifest" unless manifest.is_a?(Hash)

      @root_entry = parse_entry(manifest["root"], "root")

      packages = manifest["packages"] || {}
      raise Invalid, "manifest packages must be an object" unless packages.is_a?(Hash)

      @package_entries = {}
      packages.each do |name, entry|
        @package_entries[name] = parse_entry(entry, "package #{name.inspect}")
      end
    end

    def parse_entry(json, what)
      raise Invalid, "manifest entry for #{what} must be an object" unless json.is_a?(Hash)

      versions = json["versions"]
      unless versions.is_a?(Array) && versions.all? { |v| v.is_a?(String) }
        raise Invalid, "manifest entry for #{what} has no version list"
      end

      deps = json["deps"]
      unless deps.is_a?(Hash) && deps.values.all? { |d| d.is_a?(Hash) }
        raise Invalid, "manifest entry for #{what} has malformed dependencies"
      end

      ordered =
        begin
          versions.map { |v| Gem::Version.new(v) }.sort
        rescue ArgumentError
          raise Invalid, "manifest entry for #{what} has an unparseable version"
        end

      {
        version_strings: ordered.map(&:to_s),
        versions: ordered,
        deps: deps
      }
    end

    def check_incompatibilities!
      nodes = @certificate.incompatibilities
      raise Invalid, "certificate has no incompatibilities" unless nodes.is_a?(Array) && !nodes.empty?

      @nodes = []
      nodes.each_with_index do |json, index|
        @nodes << parse_incompatibility(json, index)
      end
    end

    def parse_incompatibility(json, index)
      raise Invalid, "incompatibility #{index} must be an object" unless json.is_a?(Hash)

      if json.key?("id") && json["id"] != index
        raise Invalid, "incompatibility #{index} declares id #{json["id"].inspect}"
      end

      terms_json = json["terms"]
      raise Invalid, "incompatibility #{index} has no terms" unless terms_json.is_a?(Array)

      terms =
        begin
          terms_json.map { |t| Certificate.parse_term(t) }
        rescue ArgumentError, TypeError, NoMethodError => e
          raise Invalid, "incompatibility #{index} has a malformed term: #{e.message}"
        end

      cause = json["cause"]
      raise Invalid, "incompatibility #{index} has no cause" unless cause.is_a?(Hash)

      build_incompatibility(terms, cause, index)
    end

    def build_incompatibility(terms, cause, index)
      case cause["type"]
      when "root"
        incompatibility = build(terms, :root, index)
        expected = [Term.new(VersionConstraint.any(Package.root), false)]
        unless terms_equal?(incompatibility.terms, expected)
          raise Invalid, "incompatibility #{index} is not the root request"
        end
        incompatibility
      when "dependency"
        incompatibility = build(terms, :dependency, index)
        verify_dependency(incompatibility, index)
        incompatibility
      when "no_versions"
        incompatibility = build(terms, Incompatibility::NoVersions.new(nil), index)
        verify_no_versions(incompatibility, index)
        incompatibility
      when "invalid_dependency"
        dep_package = cause["dep_package"]
        raise Invalid, "incompatibility #{index} does not name its invalid dependency" unless dep_package.is_a?(String)
        incompatibility = build(terms, Incompatibility::InvalidDependency.new(dep_package, nil), index)
        verify_invalid_dependency(incompatibility, dep_package, index)
        incompatibility
      when "conflict"
        prior = cause["prior"]
        unless prior.is_a?(Array) && prior.length == 2 && prior.all? { |p| p.is_a?(Integer) }
          raise Invalid, "incompatibility #{index} has malformed premises"
        end
        prior.each do |p|
          if p < 0 || p >= index
            raise Invalid, "incompatibility #{index} references unknown derivation #{p}"
          end
        end
        incompatibility = build(
          terms,
          Incompatibility::ConflictCause.new(@nodes[prior[0]], @nodes[prior[1]]),
          index
        )
        verify_conflict(incompatibility, @nodes[prior[0]], @nodes[prior[1]], index)
        incompatibility
      else
        raise Invalid, "incompatibility #{index} has unknown cause type #{cause["type"].inspect}"
      end
    end

    def build(terms, cause, index)
      Incompatibility.new(terms, cause: cause)
    rescue ArgumentError => e
      raise Invalid, "incompatibility #{index} is malformed: #{e.message}"
    end

    # A dependency incompatibility {pkg in R, not dep in D} must come
    # straight from the frozen manifest: R is the maximal run of
    # versions of pkg sharing one original dependency requirement on
    # dep, and D is exactly that requirement parsed.
    def verify_dependency(incompatibility, index)
      terms = incompatibility.terms
      positive = terms.select(&:positive?)
      negative = terms.select(&:negative?)
      unless positive.length == 1 && negative.length == 1
        raise Invalid, "incompatibility #{index} is not a well-formed dependency"
      end

      self_term = positive[0]
      dep_term = negative[0]
      if self_term.package == dep_term.package
        raise Invalid, "incompatibility #{index} is a self-referential dependency"
      end

      entry = entry_for(self_term.package)
      unless entry
        raise Invalid, "incompatibility #{index} refers to a package missing from the manifest"
      end

      dep_name = dep_term.package.to_s
      matching = runs_for(entry, dep_name).any? do |run|
        next false if run[:value].nil?
        next false unless run[:range].eql?(self_term.constraint.range)

        constraint = parse_requirement(dep_term.package, run[:value])
        constraint && dep_term.constraint.eql?(constraint)
      end

      unless matching
        raise Invalid, "incompatibility #{index} does not follow from the manifest's dependencies"
      end
    end

    # A no-versions incompatibility is only valid if no frozen version
    # of the package falls inside the term's normalized constraint.
    def verify_no_versions(incompatibility, index)
      terms = incompatibility.terms
      unless terms.length == 1
        raise Invalid, "incompatibility #{index} is not a well-formed no-versions fact"
      end

      term = terms[0]
      if Package.root?(term.package)
        raise Invalid, "incompatibility #{index} claims the root has no versions"
      end

      entry = entry_for(term.package)
      unless entry
        raise Invalid, "incompatibility #{index} refers to a package missing from the manifest"
      end

      range = term.normalized_constraint.range
      if entry[:versions].any? { |version| range.include?(version) }
        raise Invalid, "incompatibility #{index} claims no versions, but the manifest has matching versions"
      end
    end

    # An invalid-dependency incompatibility requires the dependency to
    # be declared by the matching run of versions in the manifest, and
    # the dependency's package to be absent from the manifest.
    def verify_invalid_dependency(incompatibility, dep_package, index)
      terms = incompatibility.terms
      unless terms.length == 1 && terms[0].positive?
        raise Invalid, "incompatibility #{index} is not a well-formed invalid-dependency fact"
      end

      if @package_entries.key?(dep_package)
        raise Invalid, "incompatibility #{index} calls #{dep_package.inspect} unknown, but it is in the manifest"
      end

      entry = entry_for(terms[0].package)
      unless entry
        raise Invalid, "incompatibility #{index} refers to a package missing from the manifest"
      end

      matching = runs_for(entry, dep_package).any? do |run|
        !run[:value].nil? && run[:range].eql?(terms[0].constraint.range)
      end
      unless matching
        raise Invalid, "incompatibility #{index} does not follow from the manifest's dependencies"
      end
    end

    # A conflict step merges two premises over a shared package:
    #
    #   A = {t} + R1   B = {u} + R2   (t, u on the same package)
    #   => R1 + R2 + {inverse of (inverse(u) minus t), when non-empty}
    #
    # mirroring VersionSolver#resolve_conflict.
    def verify_conflict(incompatibility, conflict, other, index)
      conflict.terms.each do |t|
        other.terms.each do |u|
          next unless t.package == u.package

          difference = u.invert.difference(t)
          merged = (conflict.terms - [t]) + (other.terms - [u])
          merged << difference.invert unless difference.empty?

          expected = Incompatibility.new(
            merged,
            cause: Incompatibility::ConflictCause.new(conflict, other)
          )
          return if terms_equal?(expected.terms, incompatibility.terms)
        end
      end

      raise Invalid, "incompatibility #{index} is not a valid merge of its premises"
    end

    def check_conclusion!
      conclusion = @certificate.conclusion
      unless conclusion.is_a?(Integer) && conclusion >= 0 && conclusion < @nodes.length
        raise Invalid, "certificate conclusion #{conclusion.inspect} is not a known derivation"
      end

      unless @nodes[conclusion].failure?
        raise Invalid, "certificate conclusion is not a contradiction"
      end

      reachable = {}
      stack = [conclusion]
      until stack.empty?
        id = stack.pop
        next if reachable[id]
        reachable[id] = true
        cause = @certificate.incompatibilities[id]["cause"]
        stack.concat(cause["prior"]) if cause["type"] == "conflict"
      end

      if reachable.keys.none? { |id| @nodes[id].terms.any? { |t| Package.root?(t.package) } }
        check_rooted_conclusion!(conclusion)
      end

      unless reachable.size == @nodes.length
        raise Invalid, "certificate contains derivations unrelated to the conclusion"
      end
    end

    # When no derivation mentions the root package, the conclusion must
    # be the empty incompatibility produced by a final merge that forbids
    # every version of one package, and the frozen manifest must show
    # that the root request forces that package to be selected.
    def check_rooted_conclusion!(conclusion)
      package = fully_forbidden_package(conclusion)
      unless package
        raise Invalid, "certificate conclusion is not derived from the root request"
      end

      unless mandatory_from_root?(package)
        raise Invalid, "certificate conclusion does not follow from the root request"
      end
    end

    # If the conclusion is the empty incompatibility, its premises must
    # be two single-term incompatibilities on one package (the merge has
    # already been verified, which guarantees their constraints cover
    # every version). Returns that package, or nil.
    def fully_forbidden_package(conclusion)
      return nil unless @nodes[conclusion].terms.empty?

      cause = @certificate.incompatibilities[conclusion]["cause"]
      return nil unless cause["type"] == "conflict"

      premises = cause["prior"].map { |p| @nodes[p] }
      return nil unless premises.all? { |node| node.terms.length == 1 }

      terms = premises.map { |node| node.terms[0] }
      return nil unless terms[0].package == terms[1].package
      return nil if Package.root?(terms[0].package)

      terms[0].package
    end

    # Verifies, using only the frozen manifest and the certificate's
    # certified single-term exclusions, that every solution of the root
    # request must select +target+.
    def mandatory_from_root?(target)
      forbidden = forbidden_ranges
      root_deps = @root_entry[:deps].fetch(@root_entry[:version_strings].first, {})

      root_deps.any? do |name, raw|
        range = parse_range_quiet(raw)
        range && mandatory_within?(name, range, target.to_s, forbidden, {})
      end
    end

    def mandatory_within?(package, range, target, forbidden, seen)
      return true if package == target
      return false if seen[package]

      entry = @package_entries[package]
      return false unless entry

      seen = seen.merge(package => true)

      excluded = forbidden[package] || []
      allowed = entry[:versions].select { |v| range.include?(v) }
      allowed = allowed.reject { |v| excluded.any? { |fr| fr.include?(v) } }
      return false if allowed.empty?

      deps_by_version = allowed.map { |v| entry[:deps].fetch(v.to_s, {}) }
      common = deps_by_version.map(&:keys).reduce(:&) || []

      common.any? do |nxt|
        union = nil
        deps_by_version.each do |deps|
          parsed = parse_range_quiet(deps[nxt])
          break union = nil unless parsed
          union = union ? union.union(parsed) : parsed
        end
        union && mandatory_within?(nxt, union, target, forbidden, seen)
      end
    end

    # Ranges in which packages are provably forbidden, taken from the
    # certificate's verified single-term positive incompatibilities.
    def forbidden_ranges
      forbidden = Hash.new { |h, k| h[k] = [] }
      @nodes.each do |node|
        next unless node.terms.length == 1
        term = node.terms[0]
        next unless term.positive?
        next if Package.root?(term.package)
        forbidden[term.package.to_s] << term.constraint.range
      end
      forbidden
    end

    def parse_range_quiet(raw)
      PubGrub::RubyGems.parse_range(raw)
    rescue ArgumentError, Gem::Requirement::BadRequirementError
      nil
    end

    def entry_for(package)
      if Package.root?(package)
        @root_entry
      else
        @package_entries[package.to_s]
      end
    end

    # Maximal runs of consecutive versions (in sorted order) that share
    # the same original dependency requirement for +dep_name+.
    def runs_for(entry, dep_name)
      versions = entry[:version_strings]
      deps = entry[:deps]

      runs = []
      start = 0
      while start < versions.length
        value = deps.fetch(versions[start], {})[dep_name]
        stop = start + 1
        stop += 1 while stop < versions.length && deps.fetch(versions[stop], {})[dep_name] == value

        low = start == 0 ? nil : versions[start]
        high = stop == versions.length ? nil : versions[stop]
        runs << {
          value: value,
          range: VersionRange.new(
            min: low && Gem::Version.new(low),
            max: high && Gem::Version.new(high),
            include_min: !low.nil?
          )
        }
        start = stop
      end
      runs
    end

    def parse_requirement(package, raw)
      PubGrub::RubyGems.parse_constraint(package, raw)
    rescue ArgumentError, Gem::Requirement::BadRequirementError
      nil
    end

    def terms_equal?(a, b)
      a.length == b.length && a.all? { |t| b.any? { |u| t.eql?(u) } }
    end
  end
end
