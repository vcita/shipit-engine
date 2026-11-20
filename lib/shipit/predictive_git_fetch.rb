# frozen_string_literal: true
require 'fileutils'

module Shipit
  # Checkout for predictive build/branch tasks. Refreshes the stack's shared
  # git cache with the predictive branch (incremental fetch, seconds), then
  # clones locally from the cache — instead of a fresh network clone of the
  # whole repository for every one of the minutely poll tasks.
  module PredictiveGitFetch
    def fetch(predictive_target)
      branch = predictive_target.branch

      @task.acquire_git_cache_lock do
        stack_commands.fetch.run! unless Dir.exist?(@stack.git_path)
        # Forced refspec: a re-run of the same predictive branch must
        # overwrite the previously cached ref.
        git('fetch', 'origin', '--tags', "+refs/heads/#{branch}:refs/heads/#{branch}",
            env: env, chdir: @stack.git_path).run!
      end

      # A re-run of the same task would find a non-empty directory and fail
      # the clone; start from a clean, task-private directory.
      FileUtils.rm_rf(@task.working_directory)
      create_directories
      # Clone straight at the predictive branch. The cache's own checked-out branch is not updated by
      # these fetches, and `env` reads shipit.yml from the working directory, so a clone at that branch
      # gave the task the commands of an old shipit.yml.
      git('clone', '--recursive', '--origin', 'cache', '--branch', branch, @stack.git_path, '.',
          env: env, chdir: @task.working_directory).run!
      git('remote', 'add', 'origin', @stack.repo_git_url,
          env: env, chdir: @task.working_directory).run!
      # `env` above loaded the spec before the clone existed; load it again from the checkout.
      @deploy_spec = nil
    end

    def create_directories
      FileUtils.mkdir_p(@task.working_directory)
    end
  end
end
