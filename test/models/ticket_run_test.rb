# frozen_string_literal: true
require 'test_helper'

module Shipit
  class TicketRunTest < ActiveSupport::TestCase
    SHA = 'a' * 40

    setup do
      @stack = shipit_stacks(:shipit)
      configure('unit_test-ticket' => 'echo start $BRANCH')
    end

    test ".request starts the commands one time for a commit" do
      StartTicketJob.expects(:perform_later).with(@stack, SHA, 'feature-62', nil, nil).once

      assert TicketRun.request(@stack, sha: SHA, branch: 'feature-62')
      refute TicketRun.request(@stack, sha: SHA, branch: 'feature-62')
    end

    test ".request starts the commands again after the retry time" do
      StartTicketJob.expects(:perform_later).twice
      TicketRun.request(@stack, sha: SHA, branch: 'feature-62')

      travel(TicketRun::RETRY_AFTER + 1.minute) do
        Shipit.redis.del(TicketRun.key(@stack, SHA)) # travel does not move the Redis clock
        assert TicketRun.request(@stack, sha: SHA, branch: 'feature-62')
      end
    end

    test ".request passes the checks to start" do
      StartTicketJob.expects(:perform_later).with(@stack, SHA, 'feature-62', %w(unit_test-ticket), nil).once

      TicketRun.request(@stack, sha: SHA, branch: 'feature-62', checks: %w(unit_test-ticket))
    end

    test ".request does nothing for a stack without a ticket" do
      StartTicketJob.expects(:perform_later).never
      configure({})

      refute TicketRun.request(@stack, sha: SHA, branch: 'feature-62')
    end

    test "#env gives the commands the commit as the branch to test" do
      env = TicketRun.new(@stack, SHA, 'feature-62').env

      assert_equal SHA, env['BRANCH']
      assert_equal @stack.branch, env['DESTINATION_BRANCH']
      assert_equal @stack.repository.name, env['GITHUB_REPO_NAME']
      assert_equal({ @stack.github_repo_name => [SHA] }, JSON.parse(Base64.decode64(env['REPOSITORIES'])))
      assert_equal({ @stack.github_repo_name => ['feature-62'] }, JSON.parse(Base64.decode64(env['PRS_BRANCHES'])))
    end

    test "#run runs the command of each check with the env" do
      configure('lint-ticket' => 'start lint', 'unit-ticket' => 'start unit')
      ok = stub(run!: 'started')
      Command.expects(:new).with('start lint', has_entry(:env, has_entry('BRANCH', SHA))).returns(ok)
      Command.expects(:new).with('start unit', anything).returns(ok)

      TicketRun.new(@stack, SHA, 'feature-62').run
    end

    test "#run runs only the commands of the given checks" do
      configure('lint-ticket' => 'start lint', 'unit-ticket' => 'start unit')
      Command.expects(:new).with('start unit', anything).once.returns(stub(run!: 'started'))

      TicketRun.new(@stack, SHA, 'feature-62', %w(unit-ticket no-such-check)).run
    end

    test "#run executes a real command with the commit in its environment" do
      marker = File.join(Dir.tmpdir, "ticket-#{SHA}")
      FileUtils.rm_f(marker)
      configure('unit_test-ticket' => "touch #{Dir.tmpdir}/ticket-$BRANCH")

      TicketRun.new(@stack, SHA, 'feature-62').run

      assert_predicate(Pathname.new(marker), :exist?)
    ensure
      FileUtils.rm_f(marker)
    end

    test "#mergeable? reads the state of the pull request from GitHub" do
      Shipit.github.api.expects(:pull_request).with(@stack.github_repo_name, 62).returns(stub(mergeable: false))

      assert_equal false, TicketRun.new(@stack, SHA, 'feature-62').mergeable?(62)
    end

    test "#mergeable? is nil when GitHub gives an error" do
      Shipit.github.api.expects(:pull_request).raises(Octokit::NotFound)

      assert_nil TicketRun.new(@stack, SHA, 'feature-62').mergeable?(62)
    end

    test "#skip lets the next request start the commands" do
      StartTicketJob.stubs(:perform_later)
      TicketRun.request(@stack, sha: SHA, branch: 'feature-62')

      TicketRun.new(@stack, SHA, 'feature-62').skip

      assert TicketRun.request(@stack, sha: SHA, branch: 'feature-62')
    end

    test "#run lets the next request start the commands again when a command fails" do
      StartTicketJob.stubs(:perform_later)
      TicketRun.request(@stack, sha: SHA, branch: 'feature-62')
      failing = stub.tap { |command| command.stubs(:run!).raises(Command::Failed.new('no Jenkins', 1)) }
      Command.stubs(:new).returns(failing)

      TicketRun.new(@stack, SHA, 'feature-62').run

      assert TicketRun.request(@stack, sha: SHA, branch: 'feature-62')
    end

    private

    def configure(ticket)
      @stack.update!(cached_deploy_spec: DeploySpec.new('ci' => { 'ticket' => ticket }))
    end
  end
end
