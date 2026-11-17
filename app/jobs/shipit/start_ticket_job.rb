# frozen_string_literal: true
module Shipit
  class StartTicketJob < BackgroundJob
    queue_as :default

    def perform(stack, sha, branch)
      TicketRun.new(stack, sha, branch).run
    end
  end
end
