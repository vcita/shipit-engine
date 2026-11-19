# frozen_string_literal: true

module Shipit
  # Starts the ticket checks of one commit of a pull request: the commands of `ci.ticket` in the
  # stack's shipit.yml. The commands report their results as GitHub checks on that commit, and
  # MergeRequest#ticket reads them.
  class TicketRun
    # The commands do not start a second Jenkins build for a commit whose build still runs. After
    # this time a new request starts them again, for a build that Jenkins lost.
    RETRY_AFTER = 15.minutes

    def self.configured?(stack)
      spec = stack.cached_deploy_spec
      spec.present? && spec.ticket.any?
    end

    # checks: start only these checks. Without it, all the checks of the ticket.
    # number: the pull request. With it, a pull request with a merge conflict gets no checks.
    # Returns true when it started the commands for this commit.
    def self.request(stack, sha:, branch:, checks: nil, number: nil)
      return false unless configured?(stack)
      return false unless Shipit.redis.set(key(stack, sha), Time.now.to_i, nx: true, ex: RETRY_AFTER.to_i)

      StartTicketJob.perform_later(stack, sha, branch, checks, number)
      true
    end

    # Stops the builds of a commit that is not the head of its pull request any more.
    def self.abort(stack, sha:, branch:)
      return false unless configured?(stack) && stack.cached_deploy_spec.ticket_abort.any?

      AbortTicketJob.perform_later(stack, sha, branch)
      true
    end

    def self.key(stack, sha)
      "TicketRun::#{stack.id}_#{sha}"
    end

    def initialize(stack, sha, branch, checks = nil)
      @stack = stack
      @sha = sha
      @branch = branch
      @checks = checks
    end

    def run
      ticket = @stack.cached_deploy_spec.ticket
      ticket = ticket.slice(*@checks) if @checks.present?
      Dir.mktmpdir do |dir|
        ticket.each_value do |command|
          Command.new(command, env: env, chdir: dir).run!
        end
      end
    rescue Command::Error => e
      # The next request for this commit starts the commands again.
      Rails.logger.error("Train ticket checks of #{@stack.github_repo_name}@#{@sha} did not start: #{e.message}")
      Shipit.redis.del(self.class.key(@stack, @sha))
    end

    # The commands find the builds by the commit, as `run` started them with it.
    def abort
      Shipit.redis.del(self.class.key(@stack, @sha))
      Dir.mktmpdir do |dir|
        @stack.cached_deploy_spec.ticket_abort.each_value do |command|
          Command.new(command, env: env, chdir: dir).run!
        rescue Command::Error => e
          Rails.logger.error("Train ticket checks of #{@stack.github_repo_name}@#{@sha} did not stop: #{e.message}")
        end
      end
    end

    # :mergeable, :conflict, :not_head (a later push replaced the commit), or :unknown while GitHub
    # computes `mergeable`, which takes some seconds after a push.
    def state(number)
      pull_request = Shipit.github.api.pull_request(@stack.github_repo_name, number)
      return :not_head unless pull_request.head.sha == @sha
      return :unknown if pull_request.mergeable.nil?

      pull_request.mergeable ? :mergeable : :conflict
    rescue Octokit::Error => e
      Rails.logger.warn("Train ticket of #{@stack.github_repo_name}##{number}: no pull request state: #{e.message}")
      :unknown
    end

    # A later request for this commit can start the checks, for a conflict that a change of the
    # base branch removed.
    def skip
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
