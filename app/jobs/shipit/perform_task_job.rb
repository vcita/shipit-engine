# frozen_string_literal: true
module Shipit
  class PerformTaskJob < BackgroundJob
    queue_as :deploys

    def perform(task)
      @task = task
      @commands = Commands.for(@task)
      unless @task.pending?
        logger.error("Task ##{@task.id} already in `#{@task.status}` state. Aborting.")
        return
      end
      run
    ensure
      @commands.clear_working_directory
    end

    def run
      @task.ping
      @task.run!
      Rails.logger.info("Task #{@task.id} run!")
      checkout_repository
      Rails.logger.info("Task #{@task.id} checkout_repository")
      perform_task
      @task.write("\nCompleted successfully\n")
      Rails.logger.info("Task #{@task.id} Completed successfully")
      @task.report_complete!
      Rails.logger.info("Task #{@task.id} report_complete!")
    rescue Command::TimedOut => error
      @task.write("\n#{error.message}\n")
      @task.report_timeout!(error)
    rescue Command::Error => error
      @task.write("\n#{error.message}\n")
      @task.report_failure!(error)
    rescue StandardError => error
      @task.report_error!(error)
    rescue Exception => error
      @task.report_error!(error)
      raise
    end

    def abort!(signal: 'TERM')
      pid = @task.pid
      if pid
        @task.write("$ kill #{pid}\n")
        Process.kill(signal, pid)
      else
        @task.write("Can't abort, no recorded pid, WTF?\n")
      end
    rescue SystemCallError => error
      @task.write("kill: (#{pid}) - #{error.message}\n")
    end

    def check_for_abort
      @task.should_abort? do |times_killed|
        abort_msg = "Task ##{@task.id} check_for_abort"
        begin
          abort_msg += "; task data: #{@task.to_json}"
        rescue
        ensure
          abort_msg += "; backtrace: [#{Thread.current.backtrace.join(";")}]"
        end
        Rails.logger.info(abort_msg)
        if times_killed > 3
          abort!(signal: 'KILL')
        else
          abort!
        end
      end
    end

    def perform_task
      capture_all!(@commands.install_dependencies)
      Rails.logger.info("Task #{@task.id} install_dependencies")
      capture_all!(@commands.perform)
    end

    def checkout_repository
      if @task.predictive_build_id
        @commands.fetch(@task.predictive_build)
      elsif @task.predictive_branch_id
        @commands.fetch(@task.predictive_branch)
      else
        unless @commands.fetched?(@task.until_commit).tap(&:run).success?
          # acquire_git_cache_lock can take upto 15 seconds
          # to process. Try to make sure that the job isn't
          # marked dead while we attempt to acquire the lock.
          @task.ping
          @task.acquire_git_cache_lock do
            @task.ping
            unless @commands.fetched?(@task.until_commit).tap(&:run).success?
              capture!(@commands.fetch)
            end
          end
        end

        capture_all!(@commands.clone)
        capture!(@commands.checkout(@task.until_commit))
      end
    end

    def capture_all!(commands)
      commands.map { |c| capture!(c) }
    end

    def capture!(command)
      Rails.logger.info("Task #{@task.id} running command: #{command}")
      command.start do
        @task.ping
        check_for_abort
      end
      @task.write("$ #{command}\npid: #{command.pid}\n")
      @task.pid = command.pid
      command.stream! do |line|
        @task.write(line)
      end
      @task.write("\n")
      command.success?
    end

    def capture(command)
      capture!(command)
      command.success?
    rescue Command::Error
      false
    end
  end
end
