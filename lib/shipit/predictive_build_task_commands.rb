# frozen_string_literal: true
# rubocop:disable Lint/MissingSuper
require 'pathname'
require 'fileutils'

module Shipit
  class PredictiveBuildTaskCommands < TaskCommands
    SPEC_TTL = 60.minutes

    def initialize(task)
      @task = task
      @stack = task.stack
    end

    def steps
      # pipeline_spec.ci_pipeline_step(@task.type)
      deploy_spec.ci_pipeline_step(@task.predictive_task_type)
    end

    def env
      repos = {}
      pull_requests = {}
      @task.predictive_build.predictive_branches.each do |p_branch|
        branch_repo = p_branch.stack.repository
        repo_name = "#{branch_repo.owner}/#{branch_repo.name}"
        repos[repo_name] = []
        pull_requests[repo_name] = []
        p_branch.predictive_merge_requests.waiting.each do |pmr|
          repos[repo_name] << pmr.merge_request.head.sha
          pull_requests[repo_name] << pmr.merge_request.number
        end
      end

      super.merge(
        'BRANCH' => @task.predictive_build.branch,
        'PREDICTIVE_BUILD_ID' => @task.predictive_build.id.to_s,
        'DESTINATION_BRANCH' => @stack.branch,
        'REPOSITORIES' => Base64.encode64(repos.to_json),
        'PULL_REQUESTS' => Base64.strict_encode64(pull_requests.to_json),
        'TRAIN' => @task.predictive_build.red_train? ? 'true' : 'false'
      )
    end

    def pipeline_spec
      key = @task.predictive_build.pipeline.id.to_s + ':' + @task.predictive_build.branch
      Rails.cache.fetch(key, expires_in: SPEC_TTL) do
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
  end
end
