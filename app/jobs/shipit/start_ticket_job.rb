# frozen_string_literal: true
module Shipit
  class StartTicketJob < BackgroundJob
    queue_as :default

    def perform(stack, sha, branch, checks = nil)
      TicketRun.new(stack, sha, branch, checks).run
    end
  end
end
