# frozen_string_literal: true

require "test_helper"

module Shipit
  module Webhooks
    module Handlers
      module PullRequest
        class MergeQueueHandlerTest < ActiveSupport::TestCase
          setup do
            @stack = shipit_stacks(:shipit)
            @merge_request = shipit_merge_requests(:shipit_pending)
          end

          test "a close removes a queued pull request" do
            process('closed')

            assert_predicate @merge_request.reload, :canceled?
          end

          test "a close by the Shipit merge keeps the pull request" do
            process('closed', merged: true)

            assert_predicate @merge_request.reload, :pending?
          end

          test "a push removes a pull request that a running build tests" do
            put_in_running_build

            process('synchronize', sha: 'f' * 40)

            assert_predicate @merge_request.reload, :canceled?
          end

          test "a push of the tested head keeps the pull request" do
            put_in_running_build

            process('synchronize', sha: @merge_request.head.sha)

            assert_predicate @merge_request.reload, :pending?
          end

          test "a push keeps a queued pull request that no build tests yet" do
            process('synchronize', sha: 'f' * 40)

            assert_predicate @merge_request.reload, :pending?
          end

          test "ignores other pull request actions" do
            process('labeled')

            assert_predicate @merge_request.reload, :pending?
          end

          test "ignores pull requests that are not in the merge queue" do
            assert_nothing_raised { process('closed', number: 4242) }
          end

          private

          def process(action, sha: @merge_request.head.sha, merged: false, number: @merge_request.number)
            payload = payload_parsed(:pull_request_closed)
            payload['action'] = action
            payload['number'] = number
            payload['pull_request']['number'] = number
            payload['pull_request']['merged'] = merged
            payload['pull_request']['head']['sha'] = sha
            payload['pull_request']['base']['ref'] = @stack.branch
            MergeQueueHandler.new(payload).process
          end

          def put_in_running_build
            pipeline = Shipit::Pipeline.create!(name: 'shipit-test', environment: 'production')
            @stack.update_column(:pipeline_id, pipeline.id)
            build = Shipit::PredictiveBuild.create!(pipeline: pipeline, branch: 'PREDICTIVE-BRANCH-1')
            build.tasks_running
            branch = Shipit::PredictiveBranch.create!(
              predictive_build: build,
              branch: build.branch,
              stack: @stack,
              stack_commit: shipit_commits(:fifth),
            )
            Shipit::PredictiveMergeRequest.create!(merge_request: @merge_request, predictive_branch: branch, head: @merge_request.head)
          end
        end
      end
    end
  end
end
