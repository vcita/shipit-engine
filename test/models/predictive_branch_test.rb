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

    test "#update_status runs the abort again when the run step ends after the stop" do
      pmr = put_merge_request_in_branch
      @branch.tasks_canceling

      assert_enqueued_with(job: PerformTaskJob) do
        @branch.update_status(create_run_task(status: 'aborted'))
      end

      assert_equal 1, abort_tasks.count
      assert_predicate @branch.reload, :tasks_canceling?
      assert_predicate pmr.reload, :pending?
    end

    test "#update_status runs a failed abort again" do
      @branch.tasks_canceling

      @branch.update_status(create_abort_task(status: 'failed'))

      assert_equal 2, abort_tasks.count
    end

    test "a cleanup abort records the jobs and changes no status" do
      @branch.failed
      cleanup = @branch.schedule_cleanup_abort
      cleanup.update!(status: 'success')
      cleanup.write("job_name:unit_test link:https://ci/job/1/ status:ABORTED id:1\n")

      @branch.update_status(cleanup)

      assert_predicate @branch.reload, :failed?
      assert_equal %w(aborted), @branch.ci_jobs_statuses.map(&:status)
      assert_equal 1, abort_tasks.count
    end

    test "a failed cleanup abort runs again, at most #{CleanupAbort::MAX_CLEANUP_ABORTS} times" do
      @branch.tasks_canceled
      task = @branch.schedule_cleanup_abort
      while task
        task.update!(status: 'failed')
        @branch.update_status(task)
        task = abort_tasks.where.not(status: 'failed').last
      end

      assert_equal CleanupAbort::MAX_CLEANUP_ABORTS, abort_tasks.count
      assert_predicate @branch.reload, :tasks_canceled?
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

    test "#comment_msg names the failed tasks of a CI without a failed branch" do
      build = @branch.predictive_build
      CiJobsStatus.create!(predictive_build_id: build.id, name: 'common_automation', status: :failed, link: '//ci/gate/1/')
      CiJobsStatus.create!(predictive_build_id: build.id, name: 'common_build', status: :completed, link: '//ci/build/1/')
      CiJobsStatus.create!(predictive_branch_id: @branch.id, name: 'unit_test', status: :aborted, link: '//ci/test/1/')

      msg = @branch.comment_msg(PredictiveBranch::PIPELINE_TASKS_FAILED)

      assert_includes msg, "* common_automation (failed) - [//ci/gate/1/](//ci/gate/1/)"
      refute_includes msg, 'common_build'
      refute_includes msg, 'unit_test'
    end

    test "#comment_msg names the aborted tasks when no task failed" do
      CiJobsStatus.create!(predictive_branch_id: @branch.id, name: 'unit_test', status: :aborted, link: '//ci/test/1/')
      @branch.tasks_canceled

      msg = @branch.comment_msg(PredictiveBranch::STACK_TASKS_FAILED)

      assert_includes msg, "* unit_test (aborted) - [//ci/test/1/](//ci/test/1/)"
    end

    test "#comment_msg names the CI when no task failed or was aborted" do
      msg = @branch.comment_msg(PredictiveBranch::PIPELINE_TASKS_FAILED)

      assert_includes msg, "CI #{@branch.predictive_build.id} stopped"
      refute_includes msg, 'Something went wrong'
    end

    test "#reject_predictive_merge_requests keeps the queue place when no task failed" do
      pmr = put_merge_request_in_branch
      requested_at = 3.hours.ago.utc.change(usec: 0)
      pmr.merge_request.update!(merge_requested_at: requested_at)
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/keeps its place in the queue/))

      @branch.reject_predictive_merge_requests(PredictiveBranch::STACK_TASKS_FAILED)
      pmr.merge_request.reload.retry!
      pmr.merge_request.restore_queue_place!

      assert_equal requested_at, pmr.merge_request.reload.merge_requested_at
    end

    test "#reject_predictive_merge_requests does not keep the queue place after a failed task" do
      pmr = put_merge_request_in_branch
      requested_at = 3.hours.ago.utc.change(usec: 0)
      pmr.merge_request.update!(merge_requested_at: requested_at)
      CiJobsStatus.create!(predictive_branch_id: @branch.id, name: 'unit_test', status: :failed, link: '//ci/test/1/')
      MergeRequest.any_instance.expects(:set_comment).with(Not(regexp_matches(/keeps its place/)))

      @branch.reject_predictive_merge_requests(PredictiveBranch::STACK_TASKS_FAILED)
      pmr.merge_request.reload.retry!
      pmr.merge_request.restore_queue_place!

      assert_operator pmr.merge_request.reload.merge_requested_at, :>, requested_at
    end

    private

    def create_run_task(status:)
      @branch.predictive_branch_tasks.create!(
        stack: @stack, predictive_task_type: 'run', allow_concurrency: true, status: status
      )
    end

    def create_abort_task(status:)
      @branch.predictive_branch_tasks.create!(
        stack: @stack, predictive_task_type: 'abort', allow_concurrency: true, status: status
      )
    end

    def abort_tasks
      @branch.predictive_branch_tasks.where(predictive_task_type: 'abort')
    end

    def put_merge_request_in_branch(merge_request = shipit_merge_requests(:shipit_pending))
      MergeRequest.any_instance.stubs(:set_comment)
      PredictiveMergeRequest.create!(merge_request: merge_request, predictive_branch: @branch, head: merge_request.head)
    end
  end
end
