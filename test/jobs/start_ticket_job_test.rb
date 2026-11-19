# frozen_string_literal: true
require 'test_helper'

module Shipit
  class StartTicketJobTest < ActiveSupport::TestCase
    SHA = 'a' * 40

    setup do
      @stack = shipit_stacks(:shipit)
      @job = StartTicketJob.new
    end

    test "#perform starts the checks of a mergeable pull request" do
      TicketRun.any_instance.stubs(:state).with(62).returns(:mergeable)
      TicketRun.any_instance.expects(:run).once

      @job.perform(@stack, SHA, 'feature-62', nil, 62)
    end

    test "#perform starts no checks for a pull request with a merge conflict" do
      TicketRun.any_instance.stubs(:state).with(62).returns(:conflict)
      TicketRun.any_instance.expects(:run).never
      TicketRun.any_instance.expects(:skip).once
      Rails.logger.expects(:info).with(regexp_matches(/#62@#{SHA}: merge conflict/)).once

      @job.perform(@stack, SHA, 'feature-62', nil, 62)
    end

    test "#perform asks again later while GitHub has no mergeable state" do
      assert_asks_again(:unknown)
    end

    test "#perform asks again later when GitHub does not show the commit as the head" do
      assert_asks_again(:not_head)
    end

    test "#perform starts the checks when GitHub gives no mergeable state in the last attempt" do
      TicketRun.any_instance.stubs(:state).returns(:unknown)
      TicketRun.any_instance.expects(:run).once

      assert_no_enqueued_jobs(only: StartTicketJob) do
        @job.perform(@stack, SHA, 'feature-62', nil, 62, StartTicketJob::STATE_ATTEMPTS)
      end
    end

    test "#perform starts no checks for a commit that is still not the head in the last attempt" do
      TicketRun.any_instance.stubs(:state).returns(:not_head)
      TicketRun.any_instance.expects(:run).never
      TicketRun.any_instance.expects(:skip).once
      Rails.logger.expects(:info).with(regexp_matches(/#62@#{SHA}: not the head commit/)).once

      assert_no_enqueued_jobs(only: StartTicketJob) do
        @job.perform(@stack, SHA, 'feature-62', nil, 62, StartTicketJob::STATE_ATTEMPTS)
      end
    end

    test "#perform does not ask GitHub without a pull request number" do
      TicketRun.any_instance.expects(:state).never
      TicketRun.any_instance.expects(:run).once

      @job.perform(@stack, SHA, 'feature-62', %w(lint))
    end

    private

    def assert_asks_again(state)
      TicketRun.any_instance.stubs(:state).returns(state)
      TicketRun.any_instance.expects(:run).never
      TicketRun.any_instance.expects(:skip).never

      freeze_time do
        again = { job: StartTicketJob, args: [@stack, SHA, 'feature-62', nil, 62, 2] }
        assert_enqueued_with(**again, at: StartTicketJob::STATE_WAIT.from_now) do
          @job.perform(@stack, SHA, 'feature-62', nil, 62)
        end
      end
    end
  end
end
