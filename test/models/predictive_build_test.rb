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
  end
end
