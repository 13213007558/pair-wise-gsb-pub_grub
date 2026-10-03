require_relative 'failure_writer'
require_relative 'certificate'

module PubGrub
  class SolveFailure < StandardError
    attr_reader :incompatibility

    def initialize(incompatibility, source: nil)
      @incompatibility = incompatibility
      @source = source
    end

    def to_s
      "Could not find compatible versions\n\n#{explanation}"
    end

    def explanation
      @explanation ||= FailureWriter.new(@incompatibility).write
    end

    # A machine-readable proof that no solution exists, suitable for
    # independent verification by PubGrub::CertificateChecker.
    #
    # Returns nil when the failure was raised without a package source.
    def certificate
      return nil unless @source

      @certificate ||= Certificate.build(@incompatibility, @source)
    end
  end
end
