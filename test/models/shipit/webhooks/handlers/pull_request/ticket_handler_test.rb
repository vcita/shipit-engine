# frozen_string_literal: true

require "test_helper"

module Shipit
  module Webhooks
    module Handlers
      module PullRequest
        class TicketHandlerTest < ActiveSupport::TestCase
          SHA = 'b' * 40
          OLD_SHA = 'a' * 40

          setup do
            @stack = shipit_stacks(:shipit)
            @stack.update!(merge_queue_enabled: true, cached_deploy_spec: DeploySpec.new(
              'ci' => { 'ticket' => { 'unit_test-ticket' => 'echo start' } },
            ))
          end

          test "a push starts the ticket checks of the new commit" do
            StartTicketJob.expects(:perform_later).with(@stack, SHA, 'feature-62', nil, 2).once

            process('synchronize')
          end

          test "an opened, reopened or ready pull request starts the ticket checks" do
            StartTicketJob.expects(:perform_later).times(3)

            process('opened', sha: 'c' * 40)
            process('reopened', sha: 'd' * 40)
            process('ready_for_review', sha: 'e' * 40)
          end

          test "a draft, another action or another base branch starts nothing" do
            StartTicketJob.expects(:perform_later).never

            process('synchronize', draft: true)
            process('labeled')
            process('synchronize', base: 'some-other-branch')
          end

          test "a push stops the checks of the commit that it replaced" do
            with_abort_commands
            StartTicketJob.stubs(:perform_later)
            AbortTicketJob.expects(:perform_later).with(@stack, OLD_SHA, 'feature-62').once

            process('synchronize', before: OLD_SHA)
          end

          test "a push to a draft stops the old checks and starts none" do
            with_abort_commands
            StartTicketJob.expects(:perform_later).never
            AbortTicketJob.expects(:perform_later).with(@stack, OLD_SHA, 'feature-62').once

            process('synchronize', before: OLD_SHA, draft: true)
          end

          test "an opened pull request and a stack without abort commands stop nothing" do
            StartTicketJob.stubs(:perform_later)
            AbortTicketJob.expects(:perform_later).never

            process('synchronize', before: OLD_SHA)
            with_abort_commands
            process('opened', sha: 'c' * 40, before: OLD_SHA)
          end

          test "a stack without ticket checks starts nothing" do
            @stack.update!(cached_deploy_spec: DeploySpec.new('merge' => { 'train' => {} }))
            StartTicketJob.expects(:perform_later).never

            process('synchronize')
          end

          private

          def with_abort_commands
            @stack.update!(cached_deploy_spec: DeploySpec.new(
              'ci' => { 'ticket' => { 'unit_test-ticket' => { 'run' => 'echo start', 'abort' => 'echo stop' } } },
            ))
          end

          def process(action, sha: SHA, draft: false, base: @stack.branch, before: nil)
            payload = payload_parsed(:pull_request_closed)
            payload['action'] = action
            payload['before'] = before if before
            payload['pull_request']['draft'] = draft
            payload['pull_request']['head']['sha'] = sha
            payload['pull_request']['head']['ref'] = 'feature-62'
            payload['pull_request']['base']['ref'] = base
            TicketHandler.new(payload).process
          end
        end
      end
    end
  end
end
