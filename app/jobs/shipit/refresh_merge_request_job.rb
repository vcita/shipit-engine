# frozen_string_literal: true
module Shipit
  class RefreshMergeRequestJob < BackgroundJob
    queue_as :default

    def perform(merge_request)
      merge_request.refresh!

      if merge_request.root?
        merge_request.with_merge_requests.each do |mr|
          mr.schedule_refresh!
        end

        return true if merge_request.stack.pipeline
        ProcessMergeRequestsJob.perform_later(merge_request.stack)
      end
    end
  end
end
