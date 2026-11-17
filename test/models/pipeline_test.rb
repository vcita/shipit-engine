# frozen_string_literal: true
require 'test_helper'

module Shipit
  class PipelineTest < ActiveSupport::TestCase
    setup do
      @stack = shipit_stacks(:shipit)
      @pipeline = Pipeline.create!(name: 'shipit-test', environment: 'production')
      @stack.update_column(:pipeline_id, @pipeline.id)
      @pending = shipit_merge_requests(:shipit_pending)
      @unknown = shipit_merge_requests(:shipit_pending_not_mergeable_yet)

      Stack.any_instance.stubs(:allows_merges?).returns(true)
      MergeRequest.any_instance.stubs(:refresh!)
      MergeRequest.any_instance.stubs(:reject_unless_mergeable!).returns(false)
      MergeRequest.any_instance.stubs(:need_revalidation?).returns(false)
    end

    test "#remove_invalid_merge_requests keeps a pull request in the queue while GitHub computes its mergeability" do
      Shipit.github.api.expects(:add_comment).never

      valid = @pipeline.remove_invalid_merge_requests([@pending, @unknown], Pipeline::MERGE_MODE_SINGLE)

      assert_equal [@pending], valid
      assert_predicate @unknown.reload, :pending?
    end

    test "#remove_invalid_merge_requests rejects a pull request when its mergeability stays unknown too long" do
      @pipeline.remove_invalid_merge_requests([@unknown], Pipeline::MERGE_MODE_SINGLE)
      Shipit.github.api.expects(:add_comment).with(@stack.repository.full_name, @unknown.number, regexp_matches(/not mergeable yet/))

      travel(MergeRequest::MERGEABILITY_TIMEOUT + 1.minute) do
        assert_empty @pipeline.remove_invalid_merge_requests([@unknown], Pipeline::MERGE_MODE_SINGLE)
      end

      assert_predicate @unknown.reload, :rejected?
      assert_equal 'not_mergeable', @unknown.rejection_reason
    end

    test "#waiting_for_mergeability? starts a new wait after GitHub returned a mergeability" do
      assert_predicate @unknown, :waiting_for_mergeability?

      travel(MergeRequest::MERGEABILITY_TIMEOUT + 1.minute) do
        @unknown.mergeable = true
        refute_predicate @unknown, :waiting_for_mergeability?
        @unknown.mergeable = nil
        assert_predicate @unknown, :waiting_for_mergeability?
      end
    end

    test "#release_candidates skips a pull request without a rejection while a linked pull request waits for mergeability" do
      @unknown.update_column(:merge_request_id, @pending.id)
      Shipit.github.api.expects(:add_comment).never

      candidates = @pipeline.release_candidates('default')

      assert_includes candidates, shipit_merge_requests(:shipit_pending_unmergeable)
      refute_includes candidates, @pending
      assert_predicate @pending.reload, :pending?
      assert_predicate @unknown.reload, :pending?
    end

    test "#release_candidates rejects a pull request whose linked pull request was canceled" do
      @unknown.update_columns(merge_request_id: @pending.id, merge_status: 'canceled')
      linked = "#{@stack.repository.full_name}##{@unknown.number} (canceled)"
      Shipit.github.api.expects(:add_comment).with(@stack.repository.full_name, @pending.number, includes(linked))

      candidates = @pipeline.release_candidates('default')

      refute_includes candidates, @pending
      assert_predicate @pending.reload, :rejected?
      assert_equal 'with_merge_request_issue', @pending.rejection_reason
      assert_predicate @unknown.reload, :canceled?
    end

    test "#release_candidates rejects a pull request whose linked pull request is rejected in the same run" do
      @unknown.update_column(:merge_request_id, @pending.id)
      @pipeline.release_candidates('default')
      linked = "#{@stack.repository.full_name}##{@unknown.number} (rejected)"
      Shipit.github.api.expects(:add_comment).with(@stack.repository.full_name, @unknown.number, regexp_matches(/not mergeable yet/))
      Shipit.github.api.expects(:add_comment).with(@stack.repository.full_name, @pending.number, includes(linked))

      travel(MergeRequest::MERGEABILITY_TIMEOUT + 1.minute) do
        refute_includes @pipeline.release_candidates('default'), @pending
      end

      assert_predicate @pending.reload, :rejected?
      assert_equal 'with_merge_request_issue', @pending.rejection_reason
      assert_predicate @unknown.reload, :rejected?
      assert_equal 'not_mergeable', @unknown.rejection_reason
    end

    test "#release_candidates rejects a pull request whose linked pull request needs revalidation" do
      @unknown.update_columns(merge_request_id: @pending.id, merge_status: 'revalidating')
      linked = "#{@stack.repository.full_name}##{@unknown.number} (revalidating)"
      Shipit.github.api.expects(:add_comment).with(@stack.repository.full_name, @pending.number, includes(linked))

      refute_includes @pipeline.release_candidates('default'), @pending

      assert_predicate @pending.reload, :rejected?
      assert_predicate @unknown.reload, :revalidating?
    end

    test "#valid_with_merge_requests leaves out a linked pull request that is no longer queued" do
      @unknown.update_columns(merge_request_id: @pending.id, merge_status: 'canceled', mergeable: false)
      MergeRequest.any_instance.unstub(:reject_unless_mergeable!)
      Shipit.github.api.expects(:add_comment).never

      assert_empty @pipeline.valid_with_merge_requests([@pending], Pipeline::MERGE_MODE_DEFAULT)
      assert_predicate @unknown.reload, :canceled?
    end

    test "#release_candidates rejects the linked pull requests that are still queued when another one left" do
      queued = shipit_merge_requests(:shipit_mergeable_pending_ci)
      queued.update_column(:merge_request_id, @pending.id)
      @unknown.update_columns(merge_request_id: @pending.id, merge_status: 'canceled')
      linked = "#{@stack.repository.full_name}##{@unknown.number} (canceled)"
      Shipit.github.api.expects(:add_comment).with(@stack.repository.full_name, @pending.number, includes(linked))
      Shipit.github.api.expects(:add_comment).with(@stack.repository.full_name, queued.number, includes(linked))

      candidates = @pipeline.release_candidates('default')

      refute_includes candidates, @pending
      assert_predicate @pending.reload, :rejected?
      assert_predicate queued.reload, :rejected?
      assert_equal 'with_merge_request_issue', queued.rejection_reason
      assert_predicate @unknown.reload, :canceled?
    end

    test "#stats lists the pending pull requests of a stack in the order of the queue" do
      by_id = @stack.merge_requests.pending.order(:id).to_a
      by_id.each_with_index { |mr, index| mr.update_column(:merge_requested_at, (index + 1).minutes.ago) }
      name = @stack.repository.full_name

      assert_operator by_id.size, :>=, 2
      assert_equal by_id.reverse.map { |mr| "/#{name}/pull/#{mr.number}" }, @pipeline.stats[:merge_queue][name]
    end

    test "#stats lists an emergency pull request before the older requests" do
      @unknown.update_columns(mode: Pipeline::MERGE_MODE_EMERGENCY, merge_requested_at: Time.now.utc)
      name = @stack.repository.full_name

      assert_equal "/#{name}/pull/#{@unknown.number}", @pipeline.stats[:merge_queue][name].first
    end

    test "#stats lists a linked pull request at the position of its root" do
      @unknown.update_columns(merge_request_id: @pending.id, merge_requested_at: Time.now.utc)
      @pending.update_column(:merge_requested_at, 1.hour.ago)
      name = @stack.repository.full_name

      links = [@pending, @unknown].map { |mr| "/#{name}/pull/#{mr.number}" }
      assert_equal links, @pipeline.stats[:merge_queue][name].first(2)
    end

    test "#queue_message says the CI starts now when no CI runs and no pull request waits before it" do
      queue_in_order(@pending)

      assert_equal "Shipit starts the CI for this pull request within a minute.", @pipeline.queue_message(@pending)
    end

    test "#queue_message gives the place in the queue and the expected times" do
      travel_to(Time.utc(2026, 11, 17, 12, 0)) do
        queue_in_order(@unknown, @pending)
        finished_build(minutes: 40)
        finished_build(minutes: 50)
        finished_build(minutes: 60)
        running = PredictiveBuild.create!(pipeline: @pipeline, branch: 'PREDICTIVE-BRANCH-RUNNING', created_at: 10.minutes.ago)
        running.tasks_running

        msg = @pipeline.queue_message(@pending)

        # 40 minutes left in the running CI, then one CI for @unknown.
        assert_includes msg, "number 2 in the merge queue"
        assert_includes msg, "CI #{running.id} runs now (started 10 minutes ago)"
        assert_includes msg, "Expected CI start: about 13:30 UTC"
        assert_includes msg, "Expected merge: about 14:20 UTC (a CI takes about 50 minutes)"
      end
    end

    test "#queue_message gives no times before a CI of the pipeline finished" do
      queue_in_order(@unknown, @pending)

      msg = @pipeline.queue_message(@pending)

      assert_includes msg, "number 2 in the merge queue"
      refute_includes msg, "Expected"
    end

    private

    # The given pull requests first, in this order, before the other pending ones.
    def queue_in_order(*merge_requests)
      @stack.merge_requests.pending.update_all(mode: Pipeline::MERGE_MODE_SINGLE, merge_requested_at: 1.hour.ago)
      merge_requests.each_with_index do |mr, index|
        mr.update_column(:merge_requested_at, (10 - index).days.ago)
      end
    end

    def finished_build(minutes:)
      build = PredictiveBuild.create!(pipeline: @pipeline, branch: 'PREDICTIVE-BRANCH-DONE')
      build.completed
      build.update_columns(created_at: 1.day.ago, updated_at: 1.day.ago + minutes.minutes)
    end
  end
end
