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
      PredictiveBranch.any_instance.stubs(:target_branch_moved?).returns(false)
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

    test "#perform stops the CI run step, so it starts no more Jenkins jobs after the stop" do
      run_task = @branch.predictive_branch_tasks.create!(
        stack: @stack, predictive_task_type: 'run', allow_concurrency: true, status: 'running'
      )
      run_task.ping
      @first.cancel!
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)

      @job.perform(@pipeline)

      assert_predicate run_task.reload, :aborting?
      aborts = []
      run_task.should_abort? { |count| aborts << count }
      assert_equal [1], aborts
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

    test "#perform stops the build when the target branch moved and keeps its pull requests first in the queue" do
      PredictiveBranch.any_instance.stubs(:target_branch_moved?).returns(true)
      PredictiveBuild.any_instance.expects(:trigger_pipeline_tasks).with(true)
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/New commits landed on master/)).twice
      requested_at = [@first.merge_requested_at, @second.merge_requested_at]

      @job.perform(@pipeline)

      assert_predicate @build.reload, :canceled?
      assert_predicate @first_pmr.reload, :canceled?
      assert_predicate @second_pmr.reload, :canceled?
      assert_predicate @first.reload, :pending?
      assert_predicate @second.reload, :pending?
      assert_equal requested_at, [@first.merge_requested_at, @second.merge_requested_at]
    end

    test "#commits_validation names a push to the pull request, not a push to the target branch" do
      @build.tasks_completed
      @first.update!(head: shipit_commits(:first))
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/New commits were pushed/)).once
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/another pull request in it left/)).once

      @job.commits_validation(@build)

      assert_predicate @build.reload, :canceled?
      assert_predicate @first.reload, :canceled?
      assert_predicate @second.reload, :pending?
    end

    test "#merge_build puts the pull requests back in the queue when the fast-forward fails on a moved target" do
      @build.waiting_for_merging
      build = @build
      @job.define_singleton_method(:merge_predictive_branches) do |_predictive_build, _dir|
        build.merging_failed
        {}
      end
      PredictiveBuild.any_instance.stubs(:target_branch_moved?).returns(true)
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)
      @job.expects(:push_build).never

      @job.merge_build(@build)

      assert_predicate @build.reload, :canceled?
      assert_predicate @first_pmr.reload, :canceled?
      assert_predicate @first.reload, :pending?
      assert_predicate @second.reload, :pending?
    end

    test "#merge_predictive_branches keeps the predictive branch on GitHub for the check before the push" do
      @build.waiting_for_merging
      commands = stub(git_clone: stub(run!: true), git_fetch: stub(run!: true), git_merge_ff: stub(run!: true))
      commands.expects(:git_delete_branch).never
      Commands.stubs(:for).returns(commands)

      @job.merge_predictive_branches(@build, Dir.tmpdir)

      assert_predicate @build.reload, :waiting_for_merging?
    end

    test "#push_build pushes with a lease, then deletes the predictive branch" do
      @build.waiting_for_merging
      commands = mock
      order = sequence('push')
      commands.expects(:git_push_to_target).returns(stub(run!: true)).in_sequence(order)
      commands.expects(:git_last_commit).returns(stub(run!: +"#{shipit_commits(:fifth).sha}\r\n")).in_sequence(order)
      commands.expects(:git_delete_branch).with(@branch.branch).returns(stub(run!: true)).in_sequence(order)

      pushed = @job.push_build(@build, { @stack => commands })

      assert_equal [@branch], pushed
      assert_predicate @build.reload, :waiting_for_merging?
    end

    test "#merge_build puts the pull requests back in the queue when the lease rejects the push" do
      @build.waiting_for_merging
      commands = mock
      commands.expects(:git_push_to_target).returns(stub.tap { |s| s.stubs(:run!).raises(Command::Failed.new('stale info', 1)) })
      commands.expects(:git_delete_branch).never
      stack = @stack
      @job.define_singleton_method(:merge_predictive_branches) { |_predictive_build, _dir| { stack => commands } }
      # The target moves between the check before the push and the push itself.
      PredictiveBuild.any_instance.stubs(:target_branch_moved?).returns(false).then.returns(true)
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)

      @job.merge_build(@build)

      assert_predicate @build.reload, :canceled?
      assert_predicate @first.reload, :pending?
      assert_predicate @second.reload, :pending?
    end

    test "#merge_build rejects the pull requests when the push fails and the target did not move" do
      @build.waiting_for_merging
      commands = mock
      commands.expects(:git_push_to_target).returns(stub.tap { |s| s.stubs(:run!).raises(Command::Failed.new('denied', 1)) })
      stack = @stack
      @job.define_singleton_method(:merge_predictive_branches) { |_predictive_build, _dir| { stack => commands } }
      PredictiveBuild.any_instance.stubs(:target_branch_moved?).returns(false)

      @job.merge_build(@build)

      assert_predicate @build.reload, :merging_failed?
      assert_predicate @first.reload, :rejected?
    end

    test "#perform compares each predictive branch twice on the tick that merges" do
      @build.waiting_for_merging
      @job.stubs(:merge_predictive_branches).returns({})
      @job.stubs(:push_build).returns([@branch])
      PredictiveBranch.any_instance.expects(:target_branch_moved?).twice.returns(false)

      @job.perform(@pipeline)

      assert_predicate @build.reload, :completed?
    end

    test "#commits_validation fetches each merge request from GitHub once" do
      @build.tasks_completed
      @first.update!(head: shipit_commits(:first))
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)
      MergeRequest.any_instance.expects(:refresh!).twice

      @job.commits_validation(@build)

      assert_predicate @build.reload, :canceled?
    end

    test "#merge_build does not push when a pull request left the queue during the merge" do
      @build.waiting_for_merging
      first = @first
      @job.define_singleton_method(:merge_predictive_branches) do |_predictive_build, _dir|
        first.cancel!
        {}
      end
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)
      @job.expects(:push_build).never

      @job.merge_build(@build)

      assert_predicate @build.reload, :canceled?
      assert_predicate @first_pmr.reload, :canceled?
      assert_predicate @first.reload, :canceled?
    end

    test "#merging_process completes the build when a pull request is canceled during the push" do
      @build.waiting_for_merging
      first = @first
      @job.stubs(:merge_predictive_branches).returns({})
      @job.define_singleton_method(:push_build) { |_predictive_build, _commands| first.cancel! }
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/left the merge queue while Shipit merged/)).once
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/merged to branch/)).once

      @job.merging_process(@build)

      assert_predicate @build.reload, :completed?
      assert_predicate @first.reload, :canceled?
      assert_predicate @first_pmr.reload, :merged?
      assert_predicate @second.reload, :merged?
      assert_predicate @second_pmr.reload, :merged?
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
