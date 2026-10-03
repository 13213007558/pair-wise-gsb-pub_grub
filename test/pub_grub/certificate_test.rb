require "test_helper"
require "digest"
require "tmpdir"

module PubGrub
  class CertificateTest < Minitest::Test
    def solve_failure(source)
      solver = VersionSolver.new(source: source)
      solver.solve
      flunk "expected solving to fail"
    rescue SolveFailure => e
      e
    end

    def linear_source
      StaticPackageSource.new do |s|
        s.root deps: { "foo" => "~> 1.0", "baz" => "~> 1.0" }
        s.add "bar", "2.0.0", deps: { "baz" => "~> 3.0" }
        s.add "foo", "1.0.0", deps: { "bar" => "~> 2.0" }
        s.add "baz", "3.0.0"
        s.add "baz", "1.0.0"
      end
    end

    def branching_source
      StaticPackageSource.new do |s|
        s.root deps: { "foo" => "~> 1.0" }
        s.add "foo", "1.1.0", deps: { "y" => "~> 1.0", "x" => "~> 1.0" }
        s.add "foo", "1.0.0", deps: { "b" => "~> 1.0", "a" => "~> 1.0" }
        s.add "a", "1.0.0", deps: { "b" => "~> 2.0" }
        s.add "b", "2.0.0"
        s.add "b", "1.0.0"
        s.add "x", "1.0.0", deps: { "y" => "~> 2.0" }
        s.add "y", "2.0.0"
        s.add "y", "1.0.0"
      end
    end

    def no_versions_source
      StaticPackageSource.new do |s|
        s.root deps: { "foo" => ">= 2.0.0" }
        s.add "foo", "1.0.0"
      end
    end

    def invalid_dependency_source
      StaticPackageSource.new do |s|
        s.root deps: { "foo" => "~> 1.0" }
        s.add "foo", "1.0.0", deps: { "bar" => "1.0.0" }
      end
    end

    def deep_chain_source
      StaticPackageSource.new do |s|
        s.root deps: { "a" => "~> 1.0" }
        s.add "a", "1.0.0", deps: { "b" => "~> 1.0" }
        s.add "b", "1.0.0", deps: { "x" => "~> 1.0", "y" => "~> 1.0" }
        s.add "b", "1.1.0", deps: { "x" => "~> 2.0" }
        s.add "x", "1.0.0", deps: { "y" => "~> 2.0" }
        s.add "x", "2.0.0", deps: { "y" => "~> 3.0" }
        s.add "y", "1.0.0"
        s.add "y", "2.0.0"
      end
    end

    def all_sources
      [linear_source, branching_source, no_versions_source,
       invalid_dependency_source, deep_chain_source]
    end

    def assert_invalid(hash, pattern = nil)
      error = assert_raises(CertificateChecker::Invalid) do
        CertificateChecker.verify(Certificate.load(hash))
      end
      assert_match pattern, error.message if pattern
      error
    end

    def repin(hash)
      hash["manifest_sha256"] =
        Digest::SHA256.hexdigest(Certificate.canonical_json(hash["manifest"]))
      hash
    end

    def test_failure_carries_certificate
      certificate = solve_failure(linear_source).certificate

      refute_nil certificate
      assert_equal Certificate::FORMAT, certificate.to_h["format"]
      assert_kind_of Integer, certificate.conclusion
    end

    def test_failure_without_source_has_no_certificate
      failure = SolveFailure.new(solve_failure(linear_source).incompatibility)
      assert_nil failure.certificate
    end

    def test_valid_certificates_verify
      all_sources.each do |source|
        certificate = solve_failure(source).certificate

        assert CertificateChecker.verify(certificate)
        assert CertificateChecker.verify(Certificate.load(certificate.to_json))
      end
    end

    def test_manifest_freezes_versions_and_original_dependencies
      certificate = solve_failure(linear_source).certificate
      manifest = certificate.manifest

      assert_equal %w[1.0.0], manifest["packages"]["foo"]["versions"]
      assert_equal %w[1.0.0 3.0.0], manifest["packages"]["baz"]["versions"]
      assert_equal({ "bar" => "~> 2.0" }, manifest["packages"]["foo"]["deps"]["1.0.0"])
      assert_equal({ "foo" => "~> 1.0", "baz" => "~> 1.0" }, manifest["root"]["deps"]["0"])
    end

    def test_manifest_digest_matches_frozen_manifest
      certificate = solve_failure(linear_source).certificate

      expected = Digest::SHA256.hexdigest(Certificate.canonical_json(certificate.manifest))
      assert_equal expected, certificate.manifest_sha256
      assert_equal expected, certificate.to_h["manifest_sha256"]
    end

    def test_certificate_records_every_conflict_merge
      certificate = solve_failure(branching_source).certificate
      conflicts = certificate.incompatibilities.select { |n| n["cause"]["type"] == "conflict" }

      refute_empty conflicts
      conflicts.each do |node|
        prior = node["cause"]["prior"]
        assert_equal 2, prior.length
        assert prior.all? { |p| p.is_a?(Integer) && p >= 0 && p < node["id"] },
          "conflict step #{node["id"]} must reference earlier derivations"
      end
    end

    def test_tampered_version_range_rejected
      hash = solve_failure(linear_source).certificate.to_h
      node = hash["incompatibilities"].find { |n| n["cause"]["type"] == "dependency" }
      term = node["terms"].find { |t| t["range"]["type"] == "range" }
      term["range"]["min"] = "9.9.9"

      assert_invalid hash
    end

    def test_tampered_manifest_dependency_rejected
      hash = solve_failure(linear_source).certificate.to_h
      hash["manifest"]["packages"]["foo"]["deps"]["1.0.0"]["bar"] = "~> 9.0"

      # the recorded digest no longer matches the manifest
      assert_invalid(hash, /sha256/)

      # and even with a recomputed digest, derivations no longer follow
      assert_invalid repin(hash)
    end

    def test_tampered_manifest_version_list_rejected
      hash = solve_failure(no_versions_source).certificate.to_h
      hash["manifest"]["packages"]["foo"]["versions"] << "2.0.0"
      hash["manifest"]["packages"]["foo"]["deps"]["2.0.0"] = {}

      assert_invalid(hash, /sha256/)
      assert_invalid(repin(hash), /no versions/)
    end

    def test_deleted_premise_rejected
      hash = solve_failure(linear_source).certificate.to_h
      hash["incompatibilities"].delete_at(1)

      assert_invalid hash
    end

    def test_reference_to_nonexistent_derivation_rejected
      hash = solve_failure(linear_source).certificate.to_h
      node = hash["incompatibilities"].find { |n| n["cause"]["type"] == "conflict" }
      node["cause"]["prior"][0] = hash["incompatibilities"].length + 41

      assert_invalid(hash, /unknown derivation/)
    end

    def test_broken_conflict_merge_rejected
      hash = solve_failure(linear_source).certificate.to_h
      node = hash["incompatibilities"].find { |n| n["cause"]["type"] == "conflict" }
      node["terms"] = []

      assert_invalid(hash, /merge/)
    end

    def test_conclusion_must_be_a_contradiction
      hash = solve_failure(linear_source).certificate.to_h
      hash["conclusion"] = 0

      assert_invalid(hash, /contradiction/)
    end

    def test_unknown_conclusion_rejected
      hash = solve_failure(linear_source).certificate.to_h
      hash["conclusion"] = hash["incompatibilities"].length + 9

      assert_invalid(hash, /conclusion/)
    end

    def test_unrelated_derivations_rejected
      hash = solve_failure(linear_source).certificate.to_h
      extra = hash["incompatibilities"].find { |n| n["cause"]["type"] == "dependency" }.dup
      extra["id"] = hash["incompatibilities"].length
      hash["incompatibilities"] << extra

      assert_invalid(hash, /unrelated/)
    end

    def test_conflict_unrelated_to_root_rejected
      # A genuine certificate for a conflict in foo's subtree, but with
      # the root request swapped for something that never touches it.
      hash = solve_failure(branching_source).certificate.to_h
      hash["manifest"]["root"]["deps"]["0"] = { "unrelated" => ">= 1.0.0" }
      hash["manifest"]["packages"]["unrelated"] = {
        "versions" => ["1.0.0"],
        "deps" => { "1.0.0" => {} }
      }
      repin(hash)

      assert_invalid(hash, /root request/)
    end

    def test_pinned_manifest_digest
      certificate = solve_failure(linear_source).certificate

      assert CertificateChecker.verify(certificate, manifest_sha256: certificate.manifest_sha256)

      assert_raises(CertificateChecker::Invalid) do
        CertificateChecker.verify(certificate, manifest_sha256: "0" * 64)
      end
    end

    def test_cli_accepts_valid_certificate
      certificate = solve_failure(linear_source).certificate

      Dir.mktmpdir("pub_grub-test", ".") do |dir|
        path = File.join(dir, "certificate.json")
        File.write(path, certificate.to_json)

        output = `#{RbConfig.ruby} exe/pub_grub-check #{path} 2>&1`
        assert_equal 0, $?.exitstatus, output
        assert_match(/^OK/, output)

        pinned = `#{RbConfig.ruby} exe/pub_grub-check #{path} --manifest-sha256=#{certificate.manifest_sha256} 2>&1`
        assert_equal 0, $?.exitstatus, pinned
      end
    end

    def test_cli_rejects_tampered_certificate
      hash = solve_failure(linear_source).certificate.to_h
      node = hash["incompatibilities"].find { |n| n["cause"]["type"] == "dependency" }
      term = node["terms"].find { |t| t["range"]["type"] == "range" }
      term["range"]["min"] = "9.9.9"

      Dir.mktmpdir("pub_grub-test", ".") do |dir|
        path = File.join(dir, "certificate.json")
        File.write(path, JSON.generate(hash))

        output = `#{RbConfig.ruby} exe/pub_grub-check #{path} 2>&1`
        assert_equal 1, $?.exitstatus, output
        assert_match(/^INVALID/, output)
      end
    end
  end
end
