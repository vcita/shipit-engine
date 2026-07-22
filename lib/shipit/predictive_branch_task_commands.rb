# frozen_string_literal: true
# rubocop:disable Lint/MissingSuper
require 'pathname'
require 'fileutils'

module Shipit
  class PredictiveBranchTaskCommands < TaskCommands

    SPEC_TTL = 60.minutes

    def initialize(task)
      @task = task
      @stack = task.stack
    end

    def steps
      # stack_spec.ci_stack_step(@task.type)
      deploy_spec.ci_stack_step(@task.predictive_task_type)
    end

    def env
      repos = {}
      branches = {}
      branch_repo = @stack.repository
      repo_name = "#{branch_repo.owner}/#{branch_repo.name}"
      repos[repo_name] = []
      branches[repo_name] = []
      @task.predictive_branch.predictive_merge_requests.waiting.each do |pmr|
        repos[repo_name] << pmr.merge_request.head.sha
        branches[repo_name] << pmr.merge_request.branch
      end

      super.merge(
        'BRANCH' => @task.predictive_branch.branch,
        'PREDICTIVE_BUILD_ID' => @task.predictive_branch.id.to_s,
        'DESTINATION_BRANCH' => @stack.branch,
        'REPOSITORIES' => Base64.encode64(repos.to_json),
        'PRS_BRANCHES' => Base64.encode64(branches.to_json)
      )
    end

    def stack_spec
      Rails.cache.fetch(@stack.id.to_s + ':' + @task.predictive_branch.branch, expires_in: SPEC_TTL) do
        return deploy_spec
      end
    end

    def perform
      steps.map do |command_line|
        Command.new(command_line, env: env, chdir: steps_directory)
      end
    end

    include PredictiveGitFetch

    def install_dependencies
      []
    end

    protected

=begin
    TODO:
    def diff_url
      Shipit::GithubUrlHelper.github_commit_range_url(@stack, *@task.commit_range)
    end
=end
  end
end
