require "test_helper"
require "json"

module PubGrub
  class ProofCheckerTest < Minitest::Test
    def test_machine_readable_failure_proof_verifies_without_running_search
      certificate = unresolved_certificate

      result = ProofChecker.verify(certificate, { "foo" => "~> 1.0", "baz" => "~> 1.0" })

      assert result.valid?
      assert_equal certificate.fetch("proof").fetch("root"), result.root
      assert_match(/\A[0-9a-f]{64}\z/, result.root)
    end

    def test_rejects_payload_and_locally_tampered_dependency_range
      valid = unresolved_certificate
      assert ProofChecker.valid?(valid)

      certificate = Marshal.load(Marshal.dump(valid))
      node = external_node(certificate, "bar", "baz")
      node.fetch("terms").last.fetch("range").store("min", "2.0")

      tampered = Marshal.load(Marshal.dump(certificate))
      repaired = Marshal.load(Marshal.dump(certificate))
      refute ProofChecker.valid?(tampered)
      assert_invalid(rehash(repaired), /dependency range does not match original requirement/)
    end

    def test_rejects_tampered_frozen_manifest_requirement
      valid = unresolved_certificate
      certificate = Marshal.load(Marshal.dump(valid))
      manifest = certificate.fetch("proof").fetch("manifest")
      manifest.fetch("root_dependencies").store("foo", "~> 2.0")

      tampered = Marshal.load(Marshal.dump(certificate))
      refute ProofChecker.valid?(tampered)
      assert_invalid(tampered, /invalid (manifest|payload) digest/)
    end

    def test_rejects_deleted_premise
      certificate = Marshal.load(Marshal.dump(unresolved_certificate))
      root = root_node(certificate)
      removed_id = root.fetch("root_support").first
      proof = certificate.fetch("proof")
      proof.fetch("nodes").reject! { |node| node.fetch("id") == removed_id }

      repaired = Marshal.load(Marshal.dump(certificate))
      assert_invalid(rehash_with_broken_references(repaired), /missing derivation|premise is missing/)
    end

    def test_rejects_missing_derivation_reference
      certificate = Marshal.load(Marshal.dump(unresolved_certificate))
      conflict = certificate.fetch("proof").fetch("nodes").find { |node| node.fetch("type") == "conflict" }
      conflict.store("other", "0" * 64)

      assert_invalid(rehash(certificate), /missing derivation/)
    end

    def test_rejects_contradiction_unrelated_to_root
      certificate = Marshal.load(Marshal.dump(unresolved_certificate))
      root_node(certificate).store("root_support", [])

      assert_invalid(rehash(certificate), "final contradiction is not rooted in the request")
    end

    def test_rejects_non_contradiction_marked_as_root
      certificate = Marshal.load(Marshal.dump(unresolved_certificate))
      derived = certificate.fetch("proof").fetch("nodes").find do |node|
        node.fetch("type") == "conflict" &&
          !node.fetch("terms").empty? &&
          node.fetch("id") != proof_root_id(certificate)
      end
      refute_nil derived
      proof = certificate.fetch("proof")
      proof.store("root", derived.fetch("id"))
      proof.store("payload_digest", sha256(proof))
      certificate.fetch("proof").store("payload_digest", sha256(certificate.fetch("proof")))

      assert_invalid(rehash(certificate), "root derivation is not a contradiction")
    end

    private

    def unresolved_certificate
      source = StaticPackageSource.new do |s|
        s.root deps: { "foo" => "~> 1.0", "baz" => "~> 1.0" }
        s.add "bar", "2.0.0", deps: { "baz" => "~> 3.0" }
        s.add "foo", "1.0.0", deps: { "bar" => "~> 2.0" }
        s.add "baz", "3.0.0"
        s.add "baz", "1.0.0"
      end

      VersionSolver.new(source: source).solve
      flunk "expected solving to fail"
    rescue SolveFailure => failure
      failure.proof
    end

    def rehash(certificate)
      proof = certificate.fetch("proof")
      proof.store("manifest_digest", sha256(proof.fetch("manifest")))
      rehash_nodes(proof)
      certificate.store("payload_digest", sha256(proof))
      certificate
    end

    def rehash_nodes(proof)
      nodes = proof.fetch("nodes").map { |node| [node.fetch("id"), node] }.to_h
      rehash_node = lambda do |node|
        return nil unless node
        if node.fetch("type") == "conflict"
          new_conflict = rehash_node.call(nodes[node.fetch("conflict")])
          new_other = rehash_node.call(nodes[node.fetch("other")])
          node.store("conflict", new_conflict) if new_conflict
          node.store("other", new_other) if new_other
        end
        new_support = node.fetch("root_support").filter_map do |id|
          rehash_node.call(nodes[id])
        end
        node.store("root_support", new_support)
        node.store("id", sha256(node.reject { |key, _| key == "id" }))
        node.fetch("id")
      end

      new_root = rehash_node.call(nodes[proof.fetch("root")])
      proof.store("root", new_root)
      raise "root missing" unless new_root
      proof.store("nodes", nodes.values.sort_by { |node| node.fetch("id") })
    end

    def rehash_with_broken_references(certificate)
      proof = certificate.fetch("proof")
      proof.store("manifest_digest", sha256(proof.fetch("manifest")))
      table = proof.fetch("nodes").map { |node| [node.fetch("id"), node] }.to_h
      memo = {}
      rehash_node = lambda do |node|
        return nil unless node
        return memo[node] if memo.key?(node)

        memo[node] = nil
        if node.fetch("type") == "conflict"
          rehash_node.call(table[node.fetch("conflict")])
          rehash_node.call(table[node.fetch("other")])
        end
        node.fetch("root_support").each { |id| rehash_node.call(table[id]) }
        node.store("id", sha256(node.reject { |key, _| key == "id" }))
        memo[node] = node.fetch("id")
      end
      new_root = rehash_node.call(table[proof.fetch("root")])
      raise "root missing" unless new_root
      proof.store("root", new_root)
      certificate.store("payload_digest", sha256(proof))
      certificate
    end

    def sha256(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def canonical(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, result| result[key] = canonical(value[key]) }
      when Array
        value.map { |item| canonical(item) }
      else
        value
      end
    end

    def external_node(certificate, source_package, dependency_package)
      certificate.fetch("proof").fetch("nodes").find do |node|
      node.fetch("type") == "external" &&
        node.fetch("cause").fetch("type") == "dependency" &&
        node.fetch("terms").map { |term| term.fetch("package") } == [source_package, dependency_package]
    end
    end

    def root_node(certificate)
      proof = certificate.fetch("proof")
      proof.fetch("nodes").find { |node| node.fetch("id") == proof.fetch("root") }
    end

    def proof_root_id(certificate)
      certificate.fetch("proof").fetch("root")
    end

    def assert_invalid(certificate, message)
      error = assert_raises(ProofChecker::InvalidProof) do
        ProofChecker.verify(certificate)
      end
      case message
      when Regexp
        assert_match(message, error.message)
      else
        assert_equal message, error.message
      end
    end
  end
end
