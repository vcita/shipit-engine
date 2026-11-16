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
  end
end
