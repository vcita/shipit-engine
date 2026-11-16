# frozen_string_literal: true
require 'test_helper'

module Shipit
  class PredictiveBranchTest < ActiveSupport::TestCase
    setup do
      @stack = shipit_stacks(:shipit)
      pipeline = Pipeline.create!(name: 'shipit-test', environment: 'production')
      build = PredictiveBuild.create!(pipeline: pipeline, branch: 'PREDICTIVE-BRANCH-1')
      @branch = PredictiveBranch.create!(
        predictive_build: build,
        branch: build.branch,
        stack: @stack,
        stack_commit: shipit_commits(:fifth),
      )
    end

    test "#target_branch_moved? is true when the target has commits the predictive branch does not have" do
      Shipit.github.api.expects(:compare).with('shopify/shipit-engine', 'master', 'PREDICTIVE-BRANCH-1')
        .returns(stub(behind_by: 2))

      assert_predicate @branch, :target_branch_moved?
    end

    test "#target_branch_moved? is false when the predictive branch contains the target" do
      Shipit.github.api.stubs(:compare).returns(stub(behind_by: 0))

      refute_predicate @branch, :target_branch_moved?
    end

    test "#target_branch_moved? is false when GitHub cannot compare" do
      Shipit.github.api.stubs(:compare).raises(Octokit::NotFound)

      refute_predicate @branch, :target_branch_moved?
    end

    test "#target_branch_moved? is false when the compare times out" do
      Shipit.github.api.stubs(:compare).raises(Faraday::TimeoutError)

      refute_predicate @branch, :target_branch_moved?
    end

    test "#update_status ignores a run task that ends after the stop" do
      pmr = put_merge_request_in_branch
      @branch.tasks_canceling
      run_task = create_run_task(status: 'aborted')

      @branch.update_status(run_task)

      assert_predicate @branch.reload, :tasks_canceling?
      assert_predicate pmr.reload, :pending?
    end

    test "#abort_run_tasks ends a run task that never started without failing the branch" do
      pmr = put_merge_request_in_branch
      @branch.tasks_canceling
      run_task = create_run_task(status: 'pending')

      @branch.abort_run_tasks

      assert_predicate run_task.reload, :error?
      assert_predicate @branch.reload, :tasks_canceling?
      assert_predicate pmr.reload, :pending?
    end

    test "#update_completed_requests leaves a pull request that this build already rejected" do
      waiting = put_merge_request_in_branch
      rejected = put_merge_request_in_branch(shipit_merge_requests(:shipit_mergeable_pending_ci))
      rejected.merge_request.reject!('ci_failing')
      rejected.rejected

      @branch.update_completed_requests

      assert_predicate waiting.reload, :merged?
      assert_predicate waiting.merge_request.reload, :merged?
      assert_predicate rejected.merge_request.reload, :rejected?
      assert_equal 'ci_failing', rejected.merge_request.rejection_reason
    end

    test "#update_completed_requests does not reject a pull request that was queued again" do
      rejected = put_merge_request_in_branch
      rejected.rejected

      @branch.update_completed_requests

      assert_predicate rejected.merge_request.reload, :pending?
    end

    private

    def create_run_task(status:)
      @branch.predictive_branch_tasks.create!(
        stack: @stack, predictive_task_type: 'run', allow_concurrency: true, status: status
      )
    end

    def put_merge_request_in_branch(merge_request = shipit_merge_requests(:shipit_pending))
      MergeRequest.any_instance.stubs(:set_comment)
      PredictiveMergeRequest.create!(merge_request: merge_request, predictive_branch: @branch, head: merge_request.head)
    end
  end
end
