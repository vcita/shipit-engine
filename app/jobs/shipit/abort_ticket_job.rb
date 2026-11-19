# frozen_string_literal: true
module Shipit
  class AbortTicketJob < BackgroundJob
    queue_as :default

    def perform(stack, sha, branch)
      TicketRun.new(stack, sha, branch).abort
    end
  end
end
