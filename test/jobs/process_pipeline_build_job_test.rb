# frozen_string_literal: true
require 'test_helper'

module Shipit
  class ProcessPipelineBuildJobTest < ActiveSupport::TestCase
    setup do
      @stack = shipit_stacks(:shipit)
      @pipeline = Pipeline.create!(name: 'shipit-test', environment: 'production')
      @stack.update_column(:pipeline_id, @pipeline.id)

      @first = shipit_merge_requests(:shipit_pending)
      @second = shipit_merge_requests(:shipit_pending_unmergeable)

      @build = PredictiveBuild.create!(pipeline: @pipeline, branch: 'PREDICTIVE-BRANCH-1')
      @build.tasks_running
      @branch = PredictiveBranch.create!(
        predictive_build: @build,
        branch: @build.branch,
        stack: @stack,
        stack_commit: shipit_commits(:fifth),
      )
      @first_pmr = PredictiveMergeRequest.create!(merge_request: @first, predictive_branch: @branch, head: @first.head)
      @second_pmr = PredictiveMergeRequest.create!(merge_request: @second, predictive_branch: @branch, head: @second.head)

      @job = ProcessPipelineBuildJob.new
      MergeRequest.any_instance.stubs(:refresh!)
      MergeRequest.any_instance.stubs(:set_comment)
      PredictiveBranch.any_instance.stubs(:trigger_task)
    end

    test "#perform stops the build when a pull request in it is canceled" do
      @first.cancel!
      PredictiveBuild.any_instance.expects(:trigger_pipeline_tasks).with(true)

      @job.perform(@pipeline)

      assert_predicate @build.reload, :canceled?
      assert_predicate @build, :ci_pipeline_canceling?
      assert_predicate @branch.reload, :tasks_canceling?
      assert_predicate @first_pmr.reload, :canceled?
      assert_predicate @first.reload, :canceled?
    end

    test "#perform puts the other pull requests of the stopped build back in the queue" do
      original_requested_at = @second.merge_requested_at
      @first.cancel!
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)

      @job.perform(@pipeline)

      assert_predicate @second_pmr.reload, :canceled?
      assert_predicate @second.reload, :pending?
      assert_equal original_requested_at, @second.merge_requested_at
    end

    test "#perform tells each pull request why the build stopped" do
      @first.cancel!
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/left the merge queue/)).once
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/another pull request in it left/)).once

      @job.perform(@pipeline)
    end

    test "#perform names new commits as the reason when the head changed" do
      @first.update!(head: shipit_commits(:first))
      @first.cancel!
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/New commits were pushed/)).once
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/another pull request in it left/)).once

      @job.perform(@pipeline)
    end

    test "#perform names the close as the reason for a closed pull request" do
      @first.update!(state: 'closed')
      @first.cancel!
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/was closed/)).once
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/another pull request in it left/)).once

      @job.perform(@pipeline)
    end

    test "#perform keeps the build when every pull request is still queued" do
      @job.expects(:run_tasks).with(@build)

      @job.perform(@pipeline)

      assert_predicate @build.reload, :tasks_running?
      assert_predicate @first_pmr.reload, :pending?
    end

    test "#merge_build does not push when a pull request left the queue during the merge" do
      @build.waiting_for_merging
      @job.stubs(:merge_predictive_branches).returns({})
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)
      @first.cancel!
      @job.expects(:push_build).never

      @job.merge_build(@build)

      assert_predicate @build.reload, :canceled?
      assert_predicate @first_pmr.reload, :canceled?
      assert_predicate @first.reload, :canceled?
    end

    test "#merging_process does not merge a build with a canceled predictive merge request" do
      @build.tasks_completed
      @second_pmr.canceled
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)
      @job.expects(:merge_build).never

      @job.merging_process(@build)

      assert_predicate @build.reload, :canceled?
      assert_predicate @first.reload, :pending?
    end
  end
end
