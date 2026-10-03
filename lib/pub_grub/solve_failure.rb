require_relative 'failure_writer'
require_relative 'failure_proof'

module PubGrub
  class SolveFailure < StandardError
    attr_reader :incompatibility, :proof

    def initialize(incompatibility, source: nil)
      @incompatibility = incompatibility
      @proof = FailureProof.build(incompatibility, source: source) if source
    end

    def to_s
      "Could not find compatible versions\n\n#{explanation}"
    end

    def explanation
      @explanation ||= FailureWriter.new(@incompatibility).write
    end

    def proof_json
      proof && proof.to_json
    end
  end
end
