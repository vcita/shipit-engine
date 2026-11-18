# frozen_string_literal: true
require 'test_helper'

module Shipit
  class PredictiveBuildTest < ActiveSupport::TestCase
    setup do
      @stack = shipit_stacks(:shipit)
      pipeline = Pipeline.create!(name: 'shipit-test', environment: 'production')
      @build = PredictiveBuild.create!(pipeline: pipeline, branch: 'PREDICTIVE-BRANCH-1')
      @build.tasks_running
      PredictiveBranch.create!(
        predictive_build: @build,
        branch: @build.branch,
        stack: @stack,
        stack_commit: shipit_commits(:fifth),
      )
    end

    test "#update_status ignores a pipeline run task that ends after the stop" do
      @build.ci_pipeline_canceling
      run_task = @build.predictive_build_tasks.create!(
        stack: @stack, predictive_task_type: 'run', allow_concurrency: true, status: 'aborted'
      )

      @build.update_status(run_task)

      assert_predicate @build.reload, :tasks_running?
      assert_predicate @build, :ci_pipeline_canceling?
    end

    test "#update_status runs the pipeline abort again when the run step ends after the stop" do
      @build.ci_pipeline_canceling
      run_task = @build.predictive_build_tasks.create!(
        stack: @stack, predictive_task_type: 'run', allow_concurrency: true, status: 'aborted'
      )

      assert_enqueued_with(job: PerformTaskJob) do
        @build.update_status(run_task)
      end

      assert_equal 1, @build.predictive_build_tasks.where(predictive_task_type: 'abort').count
      assert_predicate @build.reload, :tasks_running?
    end

    test "a pipeline cleanup abort records the jobs and keeps the build status" do
      @build.failed
      cleanup = @build.schedule_cleanup_abort
      cleanup.update!(status: 'success')
      cleanup.write("job_name:common_automation link:https://ci/job/1/ status:ABORTED id:1\n")

      @build.update_status(cleanup)

      assert_predicate @build.reload, :failed?
      assert_equal %w(aborted), @build.ci_jobs_statuses.map(&:status)
      assert_equal 1, @build.predictive_build_tasks.where(predictive_task_type: 'abort').count
    end

    test "a failed pipeline cleanup abort keeps the build status" do
      @build.cancel
      cleanup = @build.schedule_cleanup_abort
      cleanup.update!(status: 'failed')

      @build.update_status(cleanup)

      assert_predicate @build.reload, :canceled?
      assert_equal 2, @build.predictive_build_tasks.where(predictive_task_type: 'abort').count
    end

    test "#aborting_tasks stops the pipeline run step" do
      @build.ci_pipeline_running
      run_task = @build.predictive_build_tasks.create!(
        stack: @stack, predictive_task_type: 'run', allow_concurrency: true, status: 'running'
      )
      run_task.ping
      @build.stubs(:trigger_pipeline_tasks)
      PredictiveBranch.any_instance.stubs(:trigger_task)

      @build.aborting_tasks(false, PredictiveBranch::CANCELED_DUE_TO_LEFT_QUEUE)

      assert_predicate run_task.reload, :aborting?
    end

    test "#update_status records a FAILURE report and names the failed task in the comment" do
      @build.ci_pipeline_verifying
      merge_request = shipit_merge_requests(:shipit_pending)
      PredictiveMergeRequest.create!(
        merge_request: merge_request, predictive_branch: @build.predictive_branches.first, head: merge_request.head
      )
      link = '//jenkins.example.com/job/common_automation/1/'
      job = CiJobsStatus.create!(predictive_build_id: @build.id, name: 'common_automation', status: :running, link: link)
      Shipit.github.api.expects(:add_comment).with(
        @stack.repository.full_name, merge_request.number, all_of(includes('common_automation'), includes(link))
      )

      @build.update_status(failed_verify_task("job_name:common_automation link:https:#{link} status:FAILURE id:1"))

      assert_predicate job.reload, :failed?
      assert_predicate @build.reload, :failed?
      assert_predicate merge_request.reload, :rejected?
    end

    test "#update_status creates a failed job when the first report is FAILURE" do
      @build.ci_pipeline_verifying

      @build.update_status(failed_verify_task("job_name:common_automation link:https://ci/job/1/ status:FAILURE id:1"))

      assert_equal %w(failed), @build.ci_jobs_statuses.reload.map(&:status)
      assert_predicate @build.reload, :failed?
    end

    private

    def failed_verify_task(output)
      @build.stubs(:trigger_pipeline_tasks)
      PredictiveBranch.any_instance.stubs(:trigger_task)
      task = @build.predictive_build_tasks.create!(
        stack: @stack, predictive_task_type: 'verify', allow_concurrency: true, status: 'failed'
      )
      task.write("#{output}\n")
      task
    end
  end
end
