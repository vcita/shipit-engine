# frozen_string_literal: true
module Shipit
  class DestroyStackJob < BackgroundJob
    queue_as :default

    # stack
    # +-- predictive branches, merge requests and tasks (Stack#delete_predictive_records)
    # +-- api_clients
    # +-- tasks
    # |   +-- commit_deployments
    # |   |   +-- statuses
    # |   +-- chunks
    # +-- merge_requests (before commits: head_id and base_commit_id)
    # +-- commits
    # |   +-- statuses
    # +-- github_hooks
    # +-- hooks

    def perform(stack)
      stack.delete_predictive_records
      Shipit::ApiClient.where(stack_id: stack.id).delete_all
      Shipit::Task.where(stack_id: stack.id).pluck(:id).each_slice(100) do |ids|
        Shipit::Task.delete_with_dependents(ids)
      end
      commits_ids = Shipit::Commit.where(stack_id: stack.id).pluck(:id)
      Shipit::Status.where(commit_id: commits_ids).delete_all
      Shipit::MergeRequest.where(stack_id: stack.id).delete_all
      Shipit::Commit.where(id: commits_ids).delete_all
      Shipit::GithubHook.where(stack_id: stack.id).destroy_all
      Shipit::Hook.where(stack_id: stack.id).delete_all
      stack.destroy!
    end
  end
end
