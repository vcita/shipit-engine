# frozen_string_literal: true

module Shipit
  module Webhooks
    module Handlers
      module PullRequest
        # Starts the ticket checks on each new commit of a pull request, so the ticket is ready
        # when someone comments /shipit. A draft gets its checks when it is marked ready.
        class TicketHandler < Shipit::Webhooks::Handlers::Handler
          ACTIONS = %w(opened reopened synchronize ready_for_review).freeze

          params do
            requires :action, String
            requires :number, Integer
            requires :pull_request do
              accepts :draft, Axiom::Types::Boolean
              requires :head do
                requires :sha, String
                requires :ref, String
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
            return if params.pull_request.draft

            stacks.where(branch: params.pull_request.base.ref, merge_queue_enabled: true).each do |stack|
              TicketRun.request(stack, sha: params.pull_request.head.sha, branch: params.pull_request.head.ref)
            end
          end
        end
      end
    end
  end
end
