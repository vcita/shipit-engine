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
            accepts :before, String
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

            stacks.where(branch: params.pull_request.base.ref, merge_queue_enabled: true).each do |stack|
              # `before` is the head that this push replaced.
              if params.action == 'synchronize' && params.before.present?
                TicketRun.abort(stack, sha: params.before, branch: params.pull_request.head.ref)
              end
              next if params.pull_request.draft

              TicketRun.request(
                stack, sha: params.pull_request.head.sha, branch: params.pull_request.head.ref, number: params.number
              )
            end
          end
        end
      end
    end
  end
end
