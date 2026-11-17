# frozen_string_literal: true

module Shipit
  class Pipeline < Record
    include Redis::Objects
    lock :sync, timeout:60, expiration: 60

    has_many :stacks
    has_many :merge_requests, through: :stacks
    has_many :predictive_builds

    MERGE_MODE_DRY_RUN = 'dryrun'
    MERGE_MODE_DEFAULT = 'single'
    MERGE_MODE_SINGLE = 'single'
    MERGE_MODE_TRAIN = 'default'
    MERGE_MODE_PROMOTE = 'promote'
    MERGE_MODE_EMERGENCY = 'emergency'

    MERGE_MODES = %w(emergency promote single default).freeze
    MERGE_SINGLE_MODES = %w(emergency promote single).freeze
    MERGE_SINGLE_EMERGENCY = %w(emergency).freeze
    QUEUE_ORDER_MODES = %w(single default).freeze

    # The mode of a /shipit without a mode.
    def self.default_mode(stack)
      stack&.train? ? MERGE_MODE_TRAIN : MERGE_MODE_DEFAULT
    end

    # Emergency and promote go first. Single and train requests share one queue, so the
    # oldest request decides which of the two modes builds next.
    def build_modes
      queued = MergeRequest.where(stack: stacks).to_be_merged.where(mode: QUEUE_ORDER_MODES).pluck(:mode).uniq
      [MERGE_MODE_EMERGENCY, MERGE_MODE_PROMOTE] + queued + (QUEUE_ORDER_MODES - queued)
    end

    # merge_requests
    def release_candidates(mode)
      update_rejected_stacks(mode)
      stacks = mergeable_stacks(mode)
      # Find root merge_requests candidates
      merge_requests = MergeRequest.where(stack: stacks).to_be_merged.mode(mode)
      merge_requests = remove_invalid_merge_requests(merge_requests, mode)

      # Reject candidates due to issues WITH their associated merge_requests
      valid_with = valid_with_merge_requests(merge_requests, mode)

      candidates = []
      merge_requests.each do |merge_request|
        queued_with = merge_request.with_merge_requests.select(&:pending?)
        next if queued_with.any?(&:waiting_for_mergeability?)
        next if mode != MERGE_MODE_EMERGENCY && queued_with.any?(&:waiting_for_ticket?)

        invalid_with = merge_request.with_merge_requests.reject { |with_mr| valid_with.include?(with_mr) }
        if invalid_with.any?
          reject_with_invalid_merge_requests(merge_request, invalid_with)
        else
          candidates << merge_request
        end
      end

      candidates
    end

    # Takes the candidates in queue order while each stack stays under its caps. The first
    # candidate always boards, so a pull request over the commit cap can still merge.
    def train_passengers(candidates)
      prs = Hash.new(0)
      commits = Hash.new(0)
      candidates.select do |candidate|
        group = ([candidate] + candidate.with_merge_requests).group_by(&:stack)
        next false unless prs.empty? || group.all? { |stack, mrs| train_has_room?(stack, mrs, prs, commits) }

        group.each do |stack, mrs|
          prs[stack.id] += mrs.size
          commits[stack.id] += mrs.sum(&:commits_count) if train_caps(stack).last.positive?
        end
        true
      end
    end

    # A linked pull request can be canceled, rejected or revalidating while the root stays pending.
    # Only pending merge requests can be rejected. A revalidating one waits for the next /shipit.
    def reject_with_invalid_merge_requests(merge_request, invalid_with)
      merge_request.reject!('with_merge_request_issue')
      queued_with = merge_request.with_merge_requests.select(&:pending?)
      queued_with.each { |with_mr| with_mr.reject!('with_merge_request_issue') }

      linked = invalid_with.map do |with_mr|
        "#{with_mr.stack.repository.full_name}##{with_mr.number} (#{with_mr.merge_status})"
      end
      msg = "Failed to process your request because a connected pull request cannot merge now: " \
            "#{linked.join(', ')}.\nComment `/shipit` again with all the connected pull requests."
      ([merge_request] + queued_with).each do |mr|
        Shipit.github.api.add_comment(mr.stack.repository.full_name, mr.number, msg)
      end
    end

    def update_rejected_stacks(mode)
      stacks = unmergeable_stacks(mode)
      merge_requests = MergeRequest.where(stack: stacks).to_be_merged.mode(mode)
      merge_requests.each do |merge_request|
        msg = "The repository does not allow merges (#{merge_request.stack.not_mergeable_reason(mode)}). \nIt's typically due to sequential CD failures. \nPlease see the [Shipit documentation - Repository does not allow merges.](https://myvcita.atlassian.net/wiki/spaces/IT/pages/2174976098/Shipit+Troubleshooting+Guide#The-repository-does-not-allow-merges%2Fdeployment-failed) to release the situation or try again later."
        Shipit.github.api.add_comment(merge_request.stack.repository.full_name, merge_request.number, msg) if msg
        merge_request.reject!("not_mergeable")
      end
    end

    def unmergeable_stacks(mode)
      stacks.select{ |s|  !s.allows_merges?(mode) }
    end

    def mergeable_stacks(mode)
      stacks.select{ |s|  s.allows_merges?(mode) }
    end

    def build_in_progress
      predictive_builds.where(status: Shipit::PredictiveBuild::WIP_STATUSES).first
    end

    def stats
      info = {
        pipeline: nil,
        merge_queue: {},
        unmergeable_stacks: unmergeable_stacks(MERGE_MODE_DEFAULT)
      }
      wip = build_in_progress
      if wip
        info[:pipeline] = {
          id: wip.id,
          repos: {},
          tasks: []
        }

        wip.ci_jobs_statuses.each do |cjs|
          info[:pipeline][:tasks] << {name: cjs.name, status: cjs.status, link: cjs.link}
        end

        wip.predictive_branches.each do |p_branch|
          prs = []
          tasks = []
          name = p_branch.stack.repository.full_name
          p_branch.predictive_merge_requests.each do |pmr|
            prs << "/#{name}/pull/#{pmr.merge_request.number}"
          end

          p_branch.ci_jobs_statuses.each do |cjs|
            tasks << {name: cjs.name, status: cjs.status, link: cjs.link}
          end

          info[:pipeline][:repos][name] = { prs: prs, tasks: tasks }
        end
      end

      stacks.each do |stack|
        queue_order(stack.merge_requests.pending).each do |mr|
          unless mr.predictive_merge_request.waiting.any?
            name = stack.repository.full_name
            info[:merge_queue][name] = [] unless info[:merge_queue][name].present?
            info[:merge_queue][name] << "/#{name}/pull/#{mr.number}"
          end
        end
      end

      info
    end

    # Builds take the modes in the order of MERGE_MODES, and the oldest request first in a mode.
    # A linked pull request goes with its root.
    def queue_order(merge_requests)
      merge_requests.sort_by do |merge_request|
        root = merge_request.with_parent_merge_request || merge_request
        [MERGE_MODES.index(root.mode) || MERGE_MODES.size, root.merge_requested_at, merge_request.id]
      end
    end

    ETA_SAMPLE_SIZE = 10

    # The reply to /shipit: the place of the pull request in the queue that the next builds use,
    # and a merge time from the recent build durations of this pipeline.
    def queue_message(merge_request)
      root = merge_request.with_parent_merge_request || merge_request
      wip = build_in_progress
      queued = queued_roots
      if !wip && queued.first == root
        return ["Shipit starts the CI for this pull request within a minute.", ticket_message(merge_request)].compact.join(" ")
      end

      ahead = queued.index(root) || queued.size
      msg = ["This pull request is number #{ahead + 1} in the merge queue."]
      if wip
        elapsed = ((Time.now - wip.created_at) / 60).to_i
        msg << "CI #{wip.id} runs now (started #{elapsed} minutes ago)."
      end
      minutes = typical_build_minutes
      if minutes
        remaining = wip ? [minutes - elapsed, 1].max : 0
        start = Time.now.utc + (remaining + ahead * minutes).minutes
        msg << "Expected CI start: about #{start.strftime('%H:%M')} UTC. " \
               "Expected merge: about #{(start + minutes.minutes).strftime('%H:%M')} UTC " \
               "(a CI takes about #{minutes} minutes)."
      end
      msg << ticket_message(merge_request)
      msg.compact.join(" ")
    end

    # The reply to /shipit must not promise a CI that waits for the ticket.
    def ticket_message(merge_request)
      checks = merge_request.stack.cached_deploy_spec&.ticket_checks || []
      return if checks.empty? || merge_request.mode == MERGE_MODE_EMERGENCY

      "The CI starts only when these checks are green on the last commit: #{checks.map { |c| "`#{c}`" }.join(', ')}."
    end

    def remove_invalid_merge_requests(merge_requests, mode)
      stacks = mergeable_stacks(mode)
      return [] unless stacks

      final_merge_requests = []

      merge_requests.each do |merge_request|
        merge_request.refresh!
        merge_request.reject_unless_mergeable!
        if merge_request.rejected?
          msg = "Pull request was rejected"
          msg = "#{msg} due to #{merge_request.rejection_reason}" if merge_request.rejection_reason
          Shipit.github.api.add_comment(merge_request.stack.repository.full_name, merge_request.number, msg)
        end
        merge_request.cancel! if merge_request.closed?
        merge_request.revalidate! if merge_request.need_revalidation?
      end

      merge_requests.select(&:pending?).each do |merge_request|
        merge_request.refresh!
        next if merge_request.waiting_for_mergeability?
        next unless ticket?(merge_request, mode)

        if !merge_request.not_mergeable_yet? && merge_request.all_status_checks_passed?
          final_merge_requests << merge_request
        else
          msg = ""
          msg = "Pull request is not mergeable yet. \nIt's typically due to one of the following reasons:\n* Github has not checked the mergeability of your PR yet: Just try again.\n* Your PR contains conflicts: Please fix the conflicts listed below and /shipit again your PR.\n* Shipit doesn't have permissions to your repository: Contact Devops team.\n For more informations please check the [Shipit documentation - Pull request is not mergeable.](https://myvcita.atlassian.net/wiki/spaces/IT/pages/2174976098/Shipit+Troubleshooting+Guide#Pull-request-is-not-mergeable-yet)." if merge_request.not_mergeable_yet?
          msg = "#{msg} Not all status checks passed. Please try again later." unless merge_request.all_status_checks_passed?
          merge_request.reject!("not_mergeable")
          Shipit.github.api.add_comment(merge_request.stack.repository.full_name, merge_request.number, msg) if msg
        end
      end

      final_merge_requests
    end

    def valid_with_merge_requests(merge_requests, mode)
      with_merge_requests = []

      merge_requests.each do |merge_request|
        with_merge_requests = with_merge_requests | merge_request.with_merge_requests # Array unique
      end

      # A canceled or rejected merge request cannot be rejected or revalidated again.
      with_merge_requests = with_merge_requests.uniq.select(&:waiting?)
      remove_invalid_merge_requests(with_merge_requests, mode)
    end

    # A pull request without a ticket gets no CI and no automation env. An emergency merge skips the ticket.
    def ticket?(merge_request, mode)
      return true if mode == MERGE_MODE_EMERGENCY

      state, checks, missing = merge_request.ticket
      merge_request.end_ticket_wait unless state == :waiting
      return true if state == :passed

      # A pull request that was open before the stack got its ticket checks, or whose checks Jenkins lost.
      if state == :waiting && missing.any? && merge_request.head
        TicketRun.request(merge_request.stack, sha: merge_request.head.sha, branch: merge_request.branch)
      end

      names = checks.map { |check| "`#{check}`" }.join(', ')
      if state == :failed
        merge_request.reject!('ticket_failed')
        merge_request.set_comment("These ticket checks failed on the last commit: #{names}. Shipit removed " \
                                  "this pull request from the merge queue. Fix the checks and comment `/shipit` again.")
      elsif merge_request.ticket_wait_started?
        merge_request.set_comment("This pull request waits for its ticket. These checks are not green on the " \
                                  "last commit: #{names}. Shipit starts the CI of the pull request when they pass.")
      elsif merge_request.ticket_timed_out?
        merge_request.end_ticket_wait
        merge_request.reject!('ticket_missing')
        merge_request.set_comment("These ticket checks gave no result in " \
                                  "#{MergeRequest::TICKET_TIMEOUT.inspect}: #{names}. Shipit removed this pull " \
                                  "request from the merge queue. Comment `/shipit` again when the checks are green.")
      end
      false
    end

    def train_caps(stack)
      spec = stack.cached_deploy_spec
      spec&.train? ? [spec.train_max_prs, spec.train_max_commits] : [0, 0]
    end

    def train_has_room?(stack, merge_requests, prs, commits)
      max_prs, max_commits = train_caps(stack)
      return false if max_prs.positive? && prs[stack.id] + merge_requests.size > max_prs

      max_commits.zero? || commits[stack.id] + merge_requests.sum(&:commits_count) <= max_commits
    end

    def self.schedule_predictive_build
      Pipeline.find_each do |pipeline|
        ProcessPipelineBuildJob.perform_later(pipeline)
      end
    end

    private

    # Roots that wait for a build. Each build takes one root and its linked pull requests.
    def queued_roots
      queue_order(merge_requests.pending.root.to_a).reject { |mr| mr.predictive_merge_request.waiting.any? }
    end

    def typical_build_minutes
      builds = predictive_builds.where(status: 'completed').order(id: :desc).limit(ETA_SAMPLE_SIZE)
      durations = builds.map { |build| (build.updated_at - build.created_at) / 60 }
      return if durations.empty?

      durations.sort[durations.size / 2].round
    end
  end
end
