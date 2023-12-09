# frozen_string_literal: true
module Shipit
  class DeployCommands < TaskCommands
    def steps
      deploy_spec.deploy_steps!
    end

    def env
      commit_sha = @task.until_commit.sha
      super.merge(
        'SHA' => commit_sha,
        'REVISION' => commit_sha,
        'DIFF_LINK' => diff_url,
      )
    end

    protected

    def diff_url
      Shipit::GithubUrlHelper.github_commit_range_url(@stack, *@task.commit_range)
    end
  end
end
