# frozen_string_literal: true

module Shipit
  module Webhooks
    module Handlers
      module PullRequest
        # Takes a pull request out of the merge queue when it is closed, or when new commits
        # are pushed while a predictive build tests it. ProcessPipelineBuildJob then stops
        # that build.
        class MergeQueueHandler < Shipit::Webhooks::Handlers::Handler
          ACTIONS = %w(closed synchronize).freeze

          params do
            requires :action, String
            requires :number, Integer
            requires :pull_request do
              requires :number, Integer
              requires :state, String
              accepts :merged, Axiom::Types::Boolean
              requires :head do
                requires :sha, String
              end
              requires :base do
                requires :ref, String
              end
            end
            requires :repository do
              requires :full_name, String
            end
          end

          def process
            return unless params.action.in?(ACTIONS)
            # Shipit closes the pull requests it merges itself.
            return if params.pull_request.merged

            merge_requests.each do |merge_request|
              next unless dequeue?(merge_request)
              merge_request.cancel!
            end
          end

          private

          def merge_requests
            stacks.where(branch: params.pull_request.base.ref, merge_queue_enabled: true).map do |stack|
              stack.merge_requests.find_by(number: params.number)
            end.compact
          end

          def dequeue?(merge_request)
            return false if merge_request.canceled? || merge_request.merged?
            return true if params.action == 'closed'

            merge_request.predictive_merge_request.waiting.any? do |pmr|
              build_running?(pmr) && (pmr.head.nil? || pmr.head.sha != params.pull_request.head.sha)
            end
          end

          # A waiting entry of a build that already ended is a leftover. No build would stop, so
          # canceling on it would take the pull request out of the queue without a comment.
          def build_running?(pmr)
            build = pmr.predictive_branch&.predictive_build
            build.present? && build.status.in?(Shipit::PredictiveBuild::WIP_STATUSES)
          end
        end
      end
    end
  end
end
