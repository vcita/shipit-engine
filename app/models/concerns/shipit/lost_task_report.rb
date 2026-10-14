# frozen_string_literal: true
module Shipit
  # A task's report hook calls update_status, which needs redis. If that raises
  # (redis restarting), the task ends but its owner stays in the running state,
  # and nothing creates a new task for a running owner.
  module LostTaskReport
    extend ActiveSupport::Concern

    # Gives the normal report hook time to land first.
    LOST_REPORT_GRACE = 2.minutes

    def replay_lost_run_report(tasks)
      task = tasks.where(predictive_task_type: 'run').order(:id).last
      return unless task&.finished? && task.updated_at < LOST_REPORT_GRACE.ago

      Rails.logger.warn("#{self.class.name} #{id}: run task #{task.id} ended #{task.status} without a status report, replaying it")
      update_status(task)
    end
  end
end
