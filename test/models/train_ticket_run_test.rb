# frozen_string_literal: true
require 'test_helper'

module Shipit
  class TrainTicketRunTest < ActiveSupport::TestCase
    SHA = 'a' * 40

    setup do
      @stack = shipit_stacks(:shipit)
      configure('ticket_checks' => %w(unit_test-ticket), 'run' => ['echo start $BRANCH'])
    end

    test ".request starts the steps one time for a commit" do
      StartTrainTicketJob.expects(:perform_later).with(@stack, SHA, 'feature-62').once

      assert TrainTicketRun.request(@stack, sha: SHA, branch: 'feature-62')
      refute TrainTicketRun.request(@stack, sha: SHA, branch: 'feature-62')
    end

    test ".request starts the steps again after the retry time" do
      StartTrainTicketJob.expects(:perform_later).twice
      TrainTicketRun.request(@stack, sha: SHA, branch: 'feature-62')

      travel(TrainTicketRun::RETRY_AFTER + 1.minute) do
        Shipit.redis.del(TrainTicketRun.key(@stack, SHA)) # travel does not move the Redis clock
        assert TrainTicketRun.request(@stack, sha: SHA, branch: 'feature-62')
      end
    end

    test ".request does nothing for a stack without ticket checks or without steps" do
      StartTrainTicketJob.expects(:perform_later).never

      configure('ticket_checks' => [], 'run' => ['echo start'])
      refute TrainTicketRun.request(@stack, sha: SHA, branch: 'feature-62')

      configure('ticket_checks' => %w(unit_test-ticket), 'run' => [])
      refute TrainTicketRun.request(@stack, sha: SHA, branch: 'feature-62')
    end

    test "#env gives the steps the commit as the branch to test" do
      env = TrainTicketRun.new(@stack, SHA, 'feature-62').env

      assert_equal SHA, env['BRANCH']
      assert_equal @stack.branch, env['DESTINATION_BRANCH']
      assert_equal @stack.repository.name, env['GITHUB_REPO_NAME']
      assert_equal({ @stack.github_repo_name => [SHA] }, JSON.parse(Base64.decode64(env['REPOSITORIES'])))
      assert_equal({ @stack.github_repo_name => ['feature-62'] }, JSON.parse(Base64.decode64(env['PRS_BRANCHES'])))
    end

    test "#run runs each step with the env" do
      configure('ticket_checks' => %w(unit_test-ticket), 'run' => ['step one', 'step two'])
      ok = stub(run!: 'started')
      Command.expects(:new).with('step one', has_entry(:env, has_entry('BRANCH', SHA))).returns(ok)
      Command.expects(:new).with('step two', anything).returns(ok)

      TrainTicketRun.new(@stack, SHA, 'feature-62').run
    end

    test "#run executes a real step with the commit in its environment" do
      marker = File.join(Dir.tmpdir, "ticket-#{SHA}")
      FileUtils.rm_f(marker)
      configure('ticket_checks' => %w(unit_test-ticket), 'run' => ["touch #{Dir.tmpdir}/ticket-$BRANCH"])

      TrainTicketRun.new(@stack, SHA, 'feature-62').run

      assert_predicate Pathname.new(marker), :exist?
    ensure
      FileUtils.rm_f(marker)
    end

    test "#run lets the next request start the steps again when a step fails" do
      StartTrainTicketJob.stubs(:perform_later)
      TrainTicketRun.request(@stack, sha: SHA, branch: 'feature-62')
      failing = stub.tap { |command| command.stubs(:run!).raises(Command::Failed.new('no Jenkins', 1)) }
      Command.stubs(:new).returns(failing)

      TrainTicketRun.new(@stack, SHA, 'feature-62').run

      assert TrainTicketRun.request(@stack, sha: SHA, branch: 'feature-62')
    end

    private

    def configure(ticket)
      @stack.update!(cached_deploy_spec: DeploySpec.new(
        'merge' => { 'train' => { 'ticket_checks' => ticket['ticket_checks'] } },
        'ci' => { 'ticket' => { 'run' => ticket['run'] } },
      ))
    end
  end
end
