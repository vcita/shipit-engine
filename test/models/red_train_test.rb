# frozen_string_literal: true
require 'test_helper'

module Shipit
  class RedTrainTest < ActiveSupport::TestCase
    setup do
      @stack = shipit_stacks(:shipit)
      @pipeline = Pipeline.create!(name: 'shipit-test', environment: 'production')
      @stack.update_column(:pipeline_id, @pipeline.id)
      @first = shipit_merge_requests(:shipit_pending)
      @second = shipit_merge_requests(:shipit_pending_unmergeable)

      @build = PredictiveBuild.create!(pipeline: @pipeline, branch: 'PREDICTIVE-BRANCH-1', mode: Pipeline::MERGE_MODE_TRAIN)
      @build.tasks_running
      @build.ci_pipeline_verifying
      @branch = PredictiveBranch.create!(
        predictive_build: @build, branch: @build.branch, stack: @stack, stack_commit: shipit_commits(:fifth)
      )
      @first_pmr = PredictiveMergeRequest.create!(merge_request: @first, predictive_branch: @branch, head: @first.head)
      @second_pmr = PredictiveMergeRequest.create!(merge_request: @second, predictive_branch: @branch, head: @second.head)

      Stack.any_instance.stubs(:train?).returns(true)
      MergeRequest.any_instance.stubs(:set_comment)
      PredictiveBuild.any_instance.stubs(:trigger_pipeline_tasks)
      PredictiveBranch.any_instance.stubs(:trigger_task)
    end

    test "a confident answer rejects the culprit and keeps the other pull request in the train queue" do
      requested_at = @second.merge_requested_at

      @build.update_status(failed_verify_task(culprit_pr: @first.number, confidence: 0.9, reason: 'It broke login'))

      assert_predicate @build.reload, :failed?
      assert_predicate @first.reload, :rejected?
      assert_equal 'train_culprit', @first.rejection_reason
      assert_predicate @first_pmr.reload, :rejected?
      assert_predicate @second.reload, :pending?
      assert_equal Pipeline::MERGE_MODE_TRAIN, @second.mode
      assert_equal requested_at, @second.merge_requested_at
      assert_predicate @second_pmr.reload, :canceled?
    end

    test "the build stores the answer, the decision and the culprit" do
      @build.update_status(failed_verify_task(culprit_pr: @first.number, confidence: 0.9, reason: 'It broke login'))

      @build.reload
      assert_equal RedTrain::DECISION_CULPRIT_REJECTED, @build.train_decision
      assert_equal @first, @build.culprit_merge_request
      assert_equal 'It broke login', JSON.parse(@build.culprit_finder_answer)['reason']
    end

    test "the culprit gets the reason and the other pull request learns that it runs again" do
      @first.expects(:set_comment).never
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/named this pull request.*It broke login/m)).once
      MergeRequest.any_instance.expects(:set_comment).with(regexp_matches(/##{@first.number} as the cause.*next train/m)).once

      @build.update_status(failed_verify_task(culprit_pr: @first.number, confidence: 0.9, reason: 'It broke login'))
    end

    test "a comment that GitHub refuses does not change the decision for the other pull requests" do
      MergeRequest.any_instance.stubs(:set_comment).raises(Octokit::BadGateway)

      @build.update_status(failed_verify_task(culprit_pr: @first.number, confidence: 0.9))

      assert_predicate @first.reload, :rejected?
      assert_predicate @second.reload, :pending?
      assert_predicate @second_pmr.reload, :canceled?
      assert_equal RedTrain::DECISION_CULPRIT_REJECTED, @build.reload.train_decision
    end

    test "no comment goes out when a state change fails" do
      PredictiveBuild.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid)
      MergeRequest.any_instance.expects(:set_comment).never

      assert_raises(ActiveRecord::RecordInvalid) do
        RedTrain.new(@build).resolve(failed_verify_task(culprit_pr: @first.number, confidence: 0.9))
      end

      assert_predicate @first.reload, :pending?
      assert_predicate @first_pmr.reload, :pending?
    end

    test "an answer below the threshold sends the pull requests to single mode" do
      @build.update_status(failed_verify_task(culprit_pr: @first.number, confidence: 0.4))

      [@first, @second].each do |merge_request|
        assert_predicate merge_request.reload, :pending?
        assert_equal Pipeline::MERGE_MODE_SINGLE, merge_request.mode
      end
      assert_predicate @first_pmr.reload, :canceled?
      assert_equal RedTrain::DECISION_LOW_CONFIDENCE, @build.reload.train_decision
    end

    test "a failed CI without an answer sends the pull requests to single mode" do
      @build.update_status(failed_verify_task(nil))

      assert_equal [Pipeline::MERGE_MODE_SINGLE] * 2, [@first, @second].map { |mr| mr.reload.mode }
      assert_equal %w(pending pending), [@first, @second].map(&:merge_status)
      assert_nil @build.reload.culprit_finder_answer
    end

    test "an answer that names a pull request outside the train sends the pull requests to single mode" do
      @build.update_status(failed_verify_task(culprit_pr: 99_999, confidence: 0.95))

      assert_equal [Pipeline::MERGE_MODE_SINGLE] * 2, [@first, @second].map { |mr| mr.reload.mode }
      assert_nil @build.reload.culprit_merge_request
    end

    test "a confident answer without a culprit runs the train again" do
      @build.update_status(failed_verify_task(culprit_pr: nil, confidence: 0.9))

      [@first, @second].each do |merge_request|
        assert_predicate merge_request.reload, :pending?
        assert_equal Pipeline::MERGE_MODE_TRAIN, merge_request.mode
      end
      assert_equal RedTrain::DECISION_NO_CULPRIT, @build.reload.train_decision
    end

    test "a second red train in a row sends the pull requests that stay to single mode" do
      earlier_red_train(@second)

      @build.update_status(failed_verify_task(culprit_pr: @first.number, confidence: 0.9))

      assert_predicate @first.reload, :rejected?
      assert_predicate @second.reload, :pending?
      assert_equal Pipeline::MERGE_MODE_SINGLE, @second.mode
    end

    test "a second red train in a row without a culprit does not run the train again" do
      earlier_red_train(@second)

      @build.update_status(failed_verify_task(culprit_pr: nil, confidence: 0.9))

      assert_equal [Pipeline::MERGE_MODE_SINGLE] * 2, [@first, @second].map { |mr| mr.reload.mode }
      assert_equal RedTrain::DECISION_SECOND_RED, @build.reload.train_decision
    end

    test "a red train before the last /shipit does not count" do
      earlier_red_train(@second, created_at: @second.merge_requested_at - 1.hour)

      @build.update_status(failed_verify_task(culprit_pr: @first.number, confidence: 0.9))

      assert_equal Pipeline::MERGE_MODE_TRAIN, @second.reload.mode
    end

    test "a train with one pull request fails as in single mode" do
      @second_pmr.destroy

      @build.update_status(failed_verify_task(culprit_pr: nil, confidence: 0.9))

      assert_predicate @first.reload, :rejected?
      assert_nil @build.reload.train_decision
    end

    test "a build on a stack without a train config rejects its pull requests" do
      Stack.any_instance.stubs(:train?).returns(false)

      @build.update_status(failed_verify_task(culprit_pr: @first.number, confidence: 0.9))

      assert_equal %w(rejected rejected), [@first, @second].map { |mr| mr.reload.merge_status }
    end

    test "a failed stack CI with two pull requests sends them to single mode" do
      @branch.task_failed

      assert_predicate @branch.reload, :failed?
      assert_equal [Pipeline::MERGE_MODE_SINGLE] * 2, [@first, @second].map { |mr| mr.reload.mode }
      assert_equal %w(pending pending), [@first, @second].map(&:merge_status)
      assert_equal RedTrain::DECISION_STACK_CI, @build.reload.train_decision
    end

    test "a failed stack CI with one pull request rejects it" do
      @second_pmr.destroy

      @branch.task_failed

      assert_predicate @first.reload, :rejected?
    end

    test ".parse_answer reads an answer that the output splits into two chunks" do
      encoded = Base64.strict_encode64({ culprit_pr: 7, confidence: 0.8 }.to_json)
      task = verify_task
      task.chunks.create!(text: "job_name:common_automation status:FAILURE\nculprit_finder_answer:#{encoded[0, 10]}")
      task.chunks.create!(text: "#{encoded[10..-1]}\n")

      assert_equal({ 'culprit_pr' => 7, 'confidence' => 0.8 }, RedTrain.parse_answer(task))
    end

    test ".parse_answer ignores an answer that is not JSON" do
      task = verify_task
      task.chunks.create!(text: "culprit_finder_answer:#{Base64.strict_encode64('not json')}\n")

      assert_nil RedTrain.parse_answer(task)
    end

    private

    def verify_task(status: 'failed')
      @build.predictive_build_tasks.create!(
        stack: @stack, predictive_task_type: 'verify', allow_concurrency: true, status: status
      )
    end

    def failed_verify_task(answer)
      task = verify_task
      task.chunks.create!(text: "culprit_finder_answer:#{Base64.strict_encode64(answer.to_json)}\n") if answer
      task
    end

    def earlier_red_train(merge_request, created_at: Time.now.utc)
      build = PredictiveBuild.create!(
        pipeline: @pipeline, branch: 'PREDICTIVE-BRANCH-0', mode: Pipeline::MERGE_MODE_TRAIN, status: 'failed'
      )
      branch = PredictiveBranch.create!(
        predictive_build: build, branch: build.branch, stack: @stack, stack_commit: shipit_commits(:fifth), status: 'failed'
      )
      PredictiveMergeRequest.create!(
        merge_request: merge_request, predictive_branch: branch, head: merge_request.head, status: 'canceled', created_at: created_at
      )
    end
  end
end
