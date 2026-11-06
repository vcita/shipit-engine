# frozen_string_literal: true
require 'test_helper'

module Shipit
  class DestroyStackJobTest < ActiveSupport::TestCase
    setup do
      @job = DestroyStackJob.new
      @stack = Stack.first
    end

    test "perform destroys the received stack" do
      Shipit.github.api.expects(:remove_hook).times(@stack.github_hooks.count)

      assert_difference -> { Stack.count }, -1 do
        @job.perform(@stack)
      end
    end

    test "perform destroys a stack that was in a predictive build" do
      stack = shipit_stacks(:shipit)
      branch = put_in_predictive_build(shipit_merge_requests(:shipit_pending))
      task_ids = branch.predictive_branch_tasks.pluck(:id)
      Shipit.legacy_github_api.stubs(:remove_hook)

      assert_difference -> { Stack.count }, -1 do
        @job.perform(stack)
      end
      assert_empty PredictiveBranch.where(id: branch.id)
      assert_empty PredictiveMergeRequest.where(predictive_branch_id: branch.id)
      assert_empty CiJobsStatus.where(predictive_branch_id: branch.id)
      assert_empty OutputChunk.where(task_id: task_ids)
    end

    test "perform destroys the CommitDeployments of the received stack" do
      stack = shipit_stacks(:shipit)
      Shipit.legacy_github_api.stubs(:remove_hook)

      assert_changes -> { CommitDeployment.count }, 'CommitDeployments not deleted' do
        @job.perform(stack)
      end
    end
  end
end
