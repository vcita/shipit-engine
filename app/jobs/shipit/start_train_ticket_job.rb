# frozen_string_literal: true
module Shipit
  class StartTrainTicketJob < BackgroundJob
    queue_as :default

    def perform(stack, sha, branch)
      TrainTicketRun.new(stack, sha, branch).run
    end
  end
end
