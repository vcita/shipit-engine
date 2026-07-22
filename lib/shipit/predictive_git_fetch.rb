# frozen_string_literal: true
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

      create_directories
      git('clone', '--recursive', '--origin', 'cache', @stack.git_path, '.',
          env: env, chdir: @task.working_directory).run!
      git('remote', 'add', 'origin', @stack.repo_git_url,
          env: env, chdir: @task.working_directory).run!
      git('checkout', '-B', branch, "cache/#{branch}",
          env: env, chdir: @task.working_directory).run!
    end

    def create_directories
      FileUtils.mkdir_p(@task.working_directory)
    end
  end
end
