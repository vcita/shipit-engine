module Shipit
  class PredictiveMergeRequest < Record
    belongs_to :merge_request
    belongs_to :predictive_branch
    belongs_to :head, class_name: 'Shipit::Commit'

    scope :waiting, -> { where(status: 'pending') }
    scope :blocked, -> { where(status: 'rejected') }
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

    def reject(msg)
      rejected
      merge_request.reject
      merge_request.with_merge_requests.each do |mr|
        mr.reject
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
