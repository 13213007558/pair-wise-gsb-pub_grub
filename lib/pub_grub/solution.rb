# frozen_string_literal: true

require "rubygems"

module PubGrub
  Provision = Struct.new(:capability, :capability_version, :package, :version, keyword_init: true)

  class Solution < Hash
    attr_reader :provisions

    def initialize(provisions = {})
      super()
      @provisions = provisions
    end
  end
end
