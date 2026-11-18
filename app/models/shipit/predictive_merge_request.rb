module Shipit
  class PredictiveMergeRequest < Record
    belongs_to :merge_request
    belongs_to :predictive_branch
    belongs_to :head, class_name: 'Shipit::Commit'

    scope :waiting, -> { where(status: 'pending') }
    scope :completed, -> { where(status: 'merged') }

    state_machine :status, initial: :pending do
      state :pending
      state :rejected
      state :canceled
      state :merged

      event :rejected do
        transition pending: :rejected
      end

      event :canceled do
        transition pending: :canceled
      end

      event :merged do
        transition pending: :merged
      end
    end

    def cancel(msg)
      canceled
      add_comment(msg)
    end

    def reject(msg, reason: nil)
      rejected
      ([merge_request] + merge_request.with_merge_requests).each do |mr|
        reason && mr.pending? ? mr.reject!(reason) : mr.reject
      end
      add_comment(msg)
    end

    def merge(msg)
      merged
      add_comment(msg)
    end

    def add_comment(msg)
      merge_request.set_comment(msg) if msg
    end

  end
end
