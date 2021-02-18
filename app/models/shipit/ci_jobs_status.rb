# frozen_string_literal: true

module Shipit
  class CiJobsStatus < Record
    belongs_to :predictive_build
    belongs_to :predictive_branch

    state_machine :status, initial: :running do
      state :running
      state :failed
      state :aborted
      state :completed

      event :running do
        transition any => :running
      end

      event :failed do
        transition any => :failed
      end

      event :aborted do
        transition any => :aborted
      end

      event :completed do
        transition any => :completed
      end

    end

  end
end
