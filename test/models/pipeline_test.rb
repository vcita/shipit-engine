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

    test "#train_passengers takes pull requests in queue order up to the cap of the stack" do
      third = shipit_merge_requests(:shipit_mergeable_pending_ci)
      train_config('max_prs' => 2)

      assert_equal [@pending, @unknown], @pipeline.train_passengers([@pending, @unknown, third])
    end

    test "#train_passengers has no cap when max_prs is 0" do
      third = shipit_merge_requests(:shipit_mergeable_pending_ci)
      train_config('max_prs' => 0)

      assert_equal [@pending, @unknown, third], @pipeline.train_passengers([@pending, @unknown, third])
    end

    test "#train_passengers counts a linked pull request against the cap" do
      third = shipit_merge_requests(:shipit_mergeable_pending_ci)
      third.update_column(:merge_request_id, @unknown.id)
      train_config('max_prs' => 2)

      assert_equal [@pending], @pipeline.train_passengers([@pending, @unknown.reload])
    end

    test "#train_passengers leaves a pull request for the next train when it goes over the commit cap" do
      third = shipit_merge_requests(:shipit_mergeable_pending_ci)
      train_config('max_prs' => 0, 'max_commits' => 5)
      @pending.stubs(:commits_count).returns(3)
      @unknown.stubs(:commits_count).returns(4)
      third.stubs(:commits_count).returns(2)

      assert_equal [@pending, third], @pipeline.train_passengers([@pending, @unknown, third])
    end

    test "#train_passengers boards the first pull request even when it is over the commit cap" do
      train_config('max_commits' => 5)
      @pending.stubs(:commits_count).returns(9)
      @unknown.stubs(:commits_count).returns(1)

      assert_equal [@pending], @pipeline.train_passengers([@pending, @unknown])
    end

    test "#build_modes builds the mode of the oldest request first, after emergency and promote" do
      MergeRequest.where(stack: @stack).update_all(merge_status: 'canceled')
      @pending.update_columns(merge_status: 'pending', mode: 'default', merge_requested_at: 9.minutes.ago)
      @unknown.update_columns(merge_status: 'pending', mode: 'single', merge_requested_at: 5.minutes.ago)

      assert_equal %w(emergency promote default single), @pipeline.build_modes

      @unknown.update_columns(merge_requested_at: 12.minutes.ago)

      assert_equal %w(emergency promote single default), @pipeline.build_modes
    end

    test ".default_mode is the train only for a stack with a train config" do
      assert_equal Pipeline::MERGE_MODE_SINGLE, Pipeline.default_mode(@stack)

      train_config({})

      assert_equal Pipeline::MERGE_MODE_TRAIN, Pipeline.default_mode(@stack.reload)
    end

    private

    def train_config(train)
      @stack.update!(cached_deploy_spec: DeploySpec.new('merge' => { 'train' => train }))
      [@pending, @unknown].each { |merge_request| merge_request.stack.reload }
    end
  end
end
