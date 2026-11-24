# frozen_string_literal: true
module Shipit
  class StartTicketJob < BackgroundJob
    STATE_ATTEMPTS = 4
    STATE_WAIT = 15.seconds
    NO_START = { conflict: 'merge conflict', not_head: 'not the head commit any more' }.freeze

    queue_as :default

    # A pull request with a merge conflict cannot merge, and a commit that a later push replaced
    # cannot get the ticket, so their checks would be wasted. GitHub can be late with both answers,
    # so the job asks again. Without a mergeable state after the last attempt, the checks start.
    def perform(stack, sha, branch, checks = nil, number = nil, attempt = 1)
      run = TicketRun.new(stack, sha, branch, checks)
      state = number ? run.state(number) : :mergeable
      if state.in?(%i(unknown not_head)) && attempt < STATE_ATTEMPTS
        return self.class.set(wait: STATE_WAIT).perform_later(stack, sha, branch, checks, number, attempt + 1)
      end
      if NO_START.key?(state)
        pull_request = "#{stack.github_repo_name}##{number}@#{sha}"
        Rails.logger.info("Train ticket of #{pull_request}: #{NO_START[state]}, no checks started")
        return run.skip
      end

      run.run
    end
  end
end
