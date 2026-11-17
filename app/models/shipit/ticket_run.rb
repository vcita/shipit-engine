# frozen_string_literal: true

module Shipit
  # Starts the ticket checks of one commit of a pull request: the `ci.ticket.run` steps of the
  # stack's shipit.yml. The steps report their results as GitHub checks on that commit, and
  # MergeRequest#ticket reads them.
  class TicketRun
    # The steps do not start a second Jenkins build for a commit whose build still runs. After
    # this time a new request starts the steps again, for a build that Jenkins lost.
    RETRY_AFTER = 15.minutes

    def self.configured?(stack)
      spec = stack.cached_deploy_spec
      spec.present? && spec.ticket_checks.any? && spec.ci_ticket_steps.any?
    end

    # Returns true when it started the steps for this commit.
    def self.request(stack, sha:, branch:)
      return false unless configured?(stack)
      return false unless Shipit.redis.set(key(stack, sha), Time.now.to_i, nx: true, ex: RETRY_AFTER.to_i)

      StartTicketJob.perform_later(stack, sha, branch)
      true
    end

    def self.key(stack, sha)
      "TicketRun::#{stack.id}_#{sha}"
    end

    def initialize(stack, sha, branch)
      @stack = stack
      @sha = sha
      @branch = branch
    end

    def run
      Dir.mktmpdir do |dir|
        @stack.cached_deploy_spec.ci_ticket_steps.each do |step|
          Command.new(step, env: env, chdir: dir).run!
        end
      end
    rescue Command::Error => e
      # The next request for this commit starts the steps again.
      Rails.logger.error("Train ticket checks of #{@stack.github_repo_name}@#{@sha} did not start: #{e.message}")
      Shipit.redis.del(self.class.key(@stack, @sha))
    end

    # BRANCH is the commit, not the branch name: the checks then test the exact commit that gets
    # the ticket, and a later push to the branch starts its own build.
    def env
      repo = @stack.github_repo_name
      Shipit.env
        .merge(@stack.env)
        .merge(@stack.cached_deploy_spec.machine_env)
        .merge(
          'BRANCH' => @sha,
          'DESTINATION_BRANCH' => @stack.branch,
          'REPOSITORIES' => Base64.strict_encode64({ repo => [@sha] }.to_json),
          'PRS_BRANCHES' => Base64.strict_encode64({ repo => [@branch] }.to_json),
        )
    end
  end
end
