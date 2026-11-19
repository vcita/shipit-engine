# frozen_string_literal: true
module Shipit
  class StartTicketJob < BackgroundJob
    MERGEABLE_ATTEMPTS = 4
    MERGEABLE_WAIT = 15.seconds

    queue_as :default

    # A pull request with a merge conflict cannot merge, so its checks would be wasted.
    # Without an answer from GitHub after the last attempt, the checks start.
    def perform(stack, sha, branch, checks = nil, number = nil, attempt = 1)
      run = TicketRun.new(stack, sha, branch, checks)
      mergeable = number ? run.mergeable?(number) : true
      if mergeable.nil? && attempt < MERGEABLE_ATTEMPTS
        return self.class.set(wait: MERGEABLE_WAIT).perform_later(stack, sha, branch, checks, number, attempt + 1)
      end
      if mergeable == false
        pull_request = "#{stack.github_repo_name}##{number}@#{sha}"
        Rails.logger.info("Train ticket of #{pull_request}: merge conflict, no checks started")
        return run.skip
      end

      run.run
    end
  end
end
