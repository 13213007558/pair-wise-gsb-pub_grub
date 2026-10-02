require_relative "pub_grub/package"
require_relative "pub_grub/platform_package"
require_relative "pub_grub/static_package_source"
require_relative "pub_grub/multi_platform_package_source"
require_relative "pub_grub/multi_platform_solution"
require_relative "pub_grub/term"
require_relative "pub_grub/version_range"
require_relative "pub_grub/version_constraint"
require_relative "pub_grub/version_union"
require_relative "pub_grub/version_solver"
require_relative "pub_grub/incompatibility"
require_relative 'pub_grub/solve_failure'
require_relative 'pub_grub/failure_writer'
require_relative 'pub_grub/version'

module PubGrub
  class << self
    attr_writer :logger

    # Solve all target platforms of a MultiPlatformPackageSource in one joint
    # run and return a MultiPlatformSolution that separates packages common to
    # every platform from platform-only packages.
    #
    # Raises SolveFailure (whose message names the conflicting platform
    # conditions) when no single set of versions satisfies every platform.
    def solve_for_platforms(source, logger: PubGrub.logger)
      unless source.is_a?(MultiPlatformPackageSource)
        raise ArgumentError, "expected a PubGrub::MultiPlatformPackageSource"
      end

      decisions = VersionSolver.new(source: source, logger: logger).solve
      common, only_on = source.partition_decisions(decisions)

      MultiPlatformSolution.new(source.platforms, common, only_on)
    end

    def logger
      @logger || default_logger
    end

    private

    def default_logger
      require "logger"

      logger = ::Logger.new(STDERR)
      logger.level = $DEBUG ? ::Logger::DEBUG : ::Logger::WARN
      @logger = logger
    end
  end
end
