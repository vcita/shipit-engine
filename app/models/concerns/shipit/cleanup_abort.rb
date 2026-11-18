# frozen_string_literal: true
module Shipit
  # The abort step can miss a Jenkins job: the run step stops only when PerformTaskJob sees the
  # abort, so it can start a job after the abort step, and a job can take longer to stop than the
  # abort command waits. A cleanup abort runs the abort commands again and changes no CI status,
  # so a job that does not stop cannot hold the queue.
  module CleanupAbort
    extend ActiveSupport::Concern

    MAX_CLEANUP_ABORTS = 3
    # Gives Jenkins time to move a build out of the queue and to end a stopped build.
    CLEANUP_ABORT_DELAY = 30.seconds

    def schedule_cleanup_abort
      count = Shipit.redis.incr(cleanup_abort_count_key)
      Shipit.redis.expire(cleanup_abort_count_key, 1.day.to_i)
      if count > MAX_CLEANUP_ABORTS
        Rails.logger.warn("#{self.class.name} #{id}: no cleanup abort left, a Jenkins job of this CI can still run")
        return
      end

      task = cleanup_abort_tasks.create!(
        user_id: Shipit::CommandLineUser.new.id,
        stack_id: cleanup_abort_stack.id,
        predictive_task_type: 'abort',
        allow_concurrency: true
      )
      Shipit.redis.set(cleanup_abort_task_key(task), 1, ex: 1.day.to_i)
      PerformTaskJob.set(wait: CLEANUP_ABORT_DELAY).perform_later(task)
      task
    end

    def cleanup_abort?(task)
      task.predictive_task_type == 'abort' && Shipit.redis.get(cleanup_abort_task_key(task)).present?
    end

    def cleanup_abort_ended(task)
      _status, jobs, _no_match = Shipit::PredictiveBuild.parse_task_output(task)
      upsert_ci_job_statuses(jobs)
      schedule_cleanup_abort unless task.status == 'success'
    end

    private

    def cleanup_abort_count_key
      "#{self.class.name}::cleanup_aborts_#{id}"
    end

    def cleanup_abort_task_key(task)
      "#{self.class.name}::cleanup_abort_task_#{task.id}"
    end
  end
end
