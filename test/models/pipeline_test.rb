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
      Commit.any_instance.stubs(:refresh_check_runs!)
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

    test "#remove_invalid_merge_requests takes a pull request into a train when its ticket checks are green" do
      ticket_config(%w(lint unit))
      ticket_status(@pending, 'lint', 'success')
      ticket_status(@pending, 'unit', 'success')
      Shipit.github.api.expects(:add_comment).never

      assert_equal [@pending], @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_TRAIN)
    end

    test "#remove_invalid_merge_requests uses the newest result of a ticket check" do
      ticket_config(%w(lint))
      ticket_status(@pending, 'lint', 'failure', created_at: 10.minutes.ago)
      ticket_status(@pending, 'lint', 'success')

      assert_equal [@pending], @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_TRAIN)
    end

    test "#remove_invalid_merge_requests reads a ticket check from a check run" do
      ticket_config(%w(lint))
      @pending.head.check_runs.create!(stack: @stack, name: 'lint', conclusion: 'success', github_id: 77, title: 'ok')

      assert_equal [@pending], @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_TRAIN)
    end

    test "#remove_invalid_merge_requests keeps a pull request in the queue while a ticket check runs, and comments one time" do
      ticket_config(%w(lint unit))
      ticket_status(@pending, 'lint', 'success')
      ticket_status(@pending, 'unit', 'pending')
      Shipit.github.api.expects(:add_comment).with(@stack.repository.full_name, @pending.number, regexp_matches(/waits for its ticket.*`unit`/m)).once

      2.times { assert_empty @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_TRAIN) }

      assert_predicate @pending.reload, :pending?
    end

    test "#remove_invalid_merge_requests starts the ticket checks that have no run on the last commit" do
      ticket_config(%w(lint unit))
      ticket_status(@pending, 'lint', 'pending')
      Shipit.github.api.stubs(:add_comment)
      TicketRun.expects(:request).with(@stack, sha: @pending.head.sha, branch: @pending.branch).once

      assert_empty @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_TRAIN)
    end

    test "#remove_invalid_merge_requests starts no ticket checks while every check runs" do
      ticket_config(%w(lint))
      ticket_status(@pending, 'lint', 'pending')
      Shipit.github.api.stubs(:add_comment)
      TicketRun.expects(:request).never

      assert_empty @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_TRAIN)
    end

    test "#remove_invalid_merge_requests rejects a pull request when a ticket check failed" do
      ticket_config(%w(lint unit))
      ticket_status(@pending, 'lint', 'failure')
      Shipit.github.api.expects(:add_comment).with(@stack.repository.full_name, @pending.number, regexp_matches(/`lint`/))

      assert_empty @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_TRAIN)

      assert_predicate @pending.reload, :rejected?
      assert_equal 'ticket_failed', @pending.rejection_reason
    end

    test "#remove_invalid_merge_requests rejects a pull request when a ticket check gives no result in time" do
      ticket_config(%w(lint))
      Shipit.github.api.stubs(:add_comment)
      @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_TRAIN)

      travel(MergeRequest::TICKET_TIMEOUT + 1.minute) do
        assert_empty @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_TRAIN)
      end

      assert_predicate @pending.reload, :rejected?
      assert_equal 'ticket_missing', @pending.rejection_reason
    end

    test "#remove_invalid_merge_requests asks for a ticket in single mode, without a train config" do
      ticket_config(%w(lint))
      ticket_status(@pending, 'lint', 'failure')
      Shipit.github.api.stubs(:add_comment)

      assert_empty @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_SINGLE)
      assert_equal 'ticket_failed', @pending.reload.rejection_reason
      assert_equal Pipeline::MERGE_MODE_SINGLE, Pipeline.default_mode(@stack.reload)
    end

    test "#remove_invalid_merge_requests asks for no ticket in emergency mode" do
      ticket_config(%w(lint))
      ticket_status(@pending, 'lint', 'failure')

      assert_equal [@pending], @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_EMERGENCY)
    end

    test "#remove_invalid_merge_requests waits for a new run when the last run of a ticket check was canceled" do
      ticket_config(%w(lint))
      @pending.head.check_runs.create!(stack: @stack, name: 'lint', conclusion: 'cancelled', github_id: 78, title: 'stopped')
      Shipit.github.api.stubs(:add_comment)
      TicketRun.expects(:request).with(@stack, sha: @pending.head.sha, branch: @pending.branch).once

      assert_empty @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_TRAIN)
      assert_predicate @pending.reload, :pending?
    end

    test "#remove_invalid_merge_requests starts the checks again when a ticket check stays in progress too long" do
      ticket_config(%w(lint))
      @pending.head.check_runs.create!(
        stack: @stack, name: 'lint', conclusion: nil, github_id: 79, title: 'running',
        created_at: (MergeRequest::TICKET_TIMEOUT + 1.minute).ago,
      )
      Shipit.github.api.stubs(:add_comment)
      TicketRun.expects(:request).with(@stack, sha: @pending.head.sha, branch: @pending.branch).once

      assert_empty @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_SINGLE)
      assert_predicate @pending.reload, :pending?
    end

    test "a rejection for another reason ends the ticket wait too" do
      ticket_config(%w(lint))
      Shipit.github.api.stubs(:add_comment)
      TicketRun.stubs(:request)
      @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_SINGLE)

      @pending.reject!('requires_rebase')

      refute_predicate @pending, :ticket_timed_out?
      assert_predicate @pending, :ticket_wait_started?
    end

    test "a cancel ends the ticket wait, so the next /shipit on the same commit waits the full time again" do
      ticket_config(%w(lint))
      Shipit.github.api.stubs(:add_comment)
      TicketRun.stubs(:request)
      @pipeline.remove_invalid_merge_requests([@pending], Pipeline::MERGE_MODE_TRAIN)

      @pending.cancel!

      refute_predicate @pending, :ticket_timed_out?
      assert_predicate @pending, :ticket_wait_started?
    end

    test "#release_candidates skips a root without a rejection while a linked pull request waits for its ticket" do
      MergeRequest.where(stack: @stack).where.not(id: [@pending.id, @unknown.id]).update_all(merge_status: 'canceled')
      @unknown.update_columns(merge_request_id: @pending.id, mergeable: true)
      ticket_config(%w(lint))
      ticket_status(@pending, 'lint', 'success')
      ticket_status(@unknown, 'lint', 'pending')
      Shipit.github.api.stubs(:add_comment)

      assert_empty @pipeline.release_candidates(Pipeline::MERGE_MODE_TRAIN)

      assert_predicate @pending.reload, :pending?
      assert_predicate @unknown.reload, :pending?
    end

    private

    def ticket_config(checks)
      @stack.update!(cached_deploy_spec: DeploySpec.new('merge' => { 'ticket_checks' => checks }))
      [@pending, @unknown].each { |merge_request| merge_request.stack.reload }
    end

    def train_config(train)
      @stack.update!(cached_deploy_spec: DeploySpec.new('merge' => { 'train' => train }))
      [@pending, @unknown].each { |merge_request| merge_request.stack.reload }
    end

    def ticket_status(merge_request, context, state, created_at: Time.now.utc)
      merge_request.head.statuses.create!(stack: @stack, context: context, state: state, created_at: created_at)
    end
  end
end
