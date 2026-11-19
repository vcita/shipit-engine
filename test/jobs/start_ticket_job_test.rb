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
      TicketRun.any_instance.stubs(:mergeable?).with(62).returns(true)
      TicketRun.any_instance.expects(:run).once

      @job.perform(@stack, SHA, 'feature-62', nil, 62)
    end

    test "#perform starts no checks for a pull request with a merge conflict" do
      TicketRun.any_instance.stubs(:mergeable?).with(62).returns(false)
      TicketRun.any_instance.expects(:run).never
      TicketRun.any_instance.expects(:skip).once

      @job.perform(@stack, SHA, 'feature-62', nil, 62)
    end

    test "#perform asks again later while GitHub has no mergeable state" do
      TicketRun.any_instance.stubs(:mergeable?).returns(nil)
      TicketRun.any_instance.expects(:run).never

      assert_enqueued_with(job: StartTicketJob, args: [@stack, SHA, 'feature-62', nil, 62, 2]) do
        @job.perform(@stack, SHA, 'feature-62', nil, 62)
      end
    end

    test "#perform starts the checks when GitHub gives no mergeable state in the last attempt" do
      TicketRun.any_instance.stubs(:mergeable?).returns(nil)
      TicketRun.any_instance.expects(:run).once

      assert_no_enqueued_jobs(only: StartTicketJob) do
        @job.perform(@stack, SHA, 'feature-62', nil, 62, StartTicketJob::MERGEABLE_ATTEMPTS)
      end
    end

    test "#perform does not ask GitHub without a pull request number" do
      TicketRun.any_instance.expects(:mergeable?).never
      TicketRun.any_instance.expects(:run).once

      @job.perform(@stack, SHA, 'feature-62', %w(lint))
    end
  end
end
