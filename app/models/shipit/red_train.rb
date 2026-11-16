# frozen_string_literal: true

module Shipit
  # Decides what happens to the pull requests of a train whose CI failed. No pull request of a
  # red train merges, so a wrong decision costs one more CI and never a bad merge.
  class RedTrain
    # The verify step of the pipeline CI prints the culprit finder's JSON answer in Base64.
    ANSWER_MARKER = %r{culprit_finder_answer:([A-Za-z0-9+/=]+)}.freeze

    DECISION_CULPRIT_REJECTED = 'culprit_rejected'
    DECISION_NO_CULPRIT = 'no_culprit'
    DECISION_LOW_CONFIDENCE = 'low_confidence'
    DECISION_SECOND_RED = 'second_red'
    DECISION_STACK_CI = 'stack_ci'

    def self.parse_answer(task)
      encoded = task&.chunks&.pluck(:text)&.join.to_s.scan(ANSWER_MARKER).last&.first
      answer = encoded && JSON.parse(Base64.decode64(encoded))
      answer if answer.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def initialize(predictive_build)
      @build = predictive_build
    end

    # The pipeline CI tested all the pull requests together.
    def resolve(task)
      answer = self.class.parse_answer(task)
      named = confident?(answer) ? named_merge_request(answer) : nil
      culprit = named && root_of(named)
      rest = roots - [culprit]
      second_red = rest.any? { |root| red_train_before?(root) }

      if culprit
        decision = DECISION_CULPRIT_REJECTED
        reject_culprit(culprit, named, answer)
        second_red ? run_alone(rest, DECISION_SECOND_RED) : run_in_next_train(rest, culprit)
      elsif second_red
        decision = DECISION_SECOND_RED
        run_alone(rest, decision)
      elsif confident?(answer) && answer['culprit_pr'].nil?
        decision = DECISION_NO_CULPRIT
        run_in_next_train(rest, nil)
      else
        decision = DECISION_LOW_CONFIDENCE
        run_alone(rest, decision)
      end

      @build.update!(culprit_finder_answer: answer&.to_json, train_decision: decision, culprit_merge_request: named)
    end

    # The stack CI tested only the pull requests of one stack, and the culprit finder does not read it.
    def resolve_stack_failure(predictive_branch)
      failed = predictive_branch.predictive_merge_requests.waiting.map { |pmr| root_of(pmr.merge_request) }.uniq
      return false if failed.size < 2

      run_alone(failed, DECISION_STACK_CI)
      @build.update!(train_decision: DECISION_STACK_CI)
      true
    end

    private

    def waiting
      @waiting ||= PredictiveMergeRequest.waiting.where(predictive_branch: @build.predictive_branches).to_a
    end

    def roots
      @roots ||= waiting.map { |pmr| root_of(pmr.merge_request) }.uniq
    end

    def root_of(merge_request)
      merge_request.with_parent_merge_request || merge_request
    end

    def group(root)
      [root] + root.with_merge_requests
    end

    def group_pmrs(root)
      waiting.select { |pmr| group(root).include?(pmr.merge_request) }
    end

    def threshold
      stacks = @build.predictive_branches.map(&:stack).select(&:train?)
      confidences = stacks.map { |stack| stack.cached_deploy_spec.train_culprit_confidence }
      confidences.max || DeploySpec::TRAIN_DEFAULT_CULPRIT_CONFIDENCE
    end

    def confident?(answer)
      answer.present? && Float(answer['confidence'], exception: false).to_f >= threshold
    end

    # A number alone can match pull requests of two repositories, so no match and two matches
    # both mean that the answer names no pull request of this train.
    def named_merge_request(answer)
      number = Integer(answer['culprit_pr'], exception: false)
      return unless number

      repo = answer['culprit_repo'].to_s.downcase
      named = waiting.map(&:merge_request).select do |mr|
        mr.number == number && (repo.empty? || mr.stack.github_repo_name.downcase == repo)
      end
      named.first if named.size == 1
    end

    def red_train_before?(root)
      PredictiveMergeRequest.joins(predictive_branch: :predictive_build)
        .where(merge_request: root)
        .where('predictive_merge_requests.created_at >= ?', root.merge_requested_at)
        .where(predictive_builds: { mode: Pipeline::MERGE_MODE_TRAIN, status: 'failed' })
        .where.not(predictive_builds: { id: @build.id })
        .exists?
    end

    def reject_culprit(culprit, named, answer)
      group_pmrs(culprit).each do |pmr|
        msg = pmr.merge_request == named ? culprit_comment(answer) : linked_culprit_comment(named)
        pmr.reject(msg, reason: 'train_culprit')
      end
    end

    def run_in_next_train(roots, culprit)
      roots.each do |root|
        group_pmrs(root).each { |pmr| pmr.cancel(next_train_comment(culprit)) }
      end
    end

    def run_alone(roots, decision)
      roots.each do |root|
        group(root).each { |mr| mr.update!(mode: Pipeline::MERGE_MODE_SINGLE) }
        group_pmrs(root).each { |pmr| pmr.cancel(alone_comment(decision)) }
      end
    end

    def link(merge_request)
      "#{merge_request.stack.github_repo_name}##{merge_request.number}"
    end

    def culprit_comment(answer)
      lines = ["CI #{@build.id} failed. The culprit finder named this pull request as the cause " \
               "(confidence #{answer['confidence']})."]
      lines << "" << "> #{answer['reason'].to_s.tr("\n", ' ').truncate(1000)}" if answer['reason'].present?
      Array(answer['evidence']).first(10).each { |evidence| lines << "* #{evidence.to_s.truncate(300)}" }
      lines << "" << "Shipit removed this pull request from the merge queue. The other pull requests of the train " \
                     "run again without it. If the finder is wrong, comment `/shipit` again."
      lines.join("\n")
    end

    def linked_culprit_comment(named)
      "CI #{@build.id} failed. The culprit finder named the connected pull request #{link(named)} as the cause, " \
        "so Shipit removed this pull request from the merge queue too."
    end

    def next_train_comment(culprit)
      cause = if culprit
        "The culprit finder named #{link(culprit)} as the cause, and Shipit removed it from the train."
      else
        "The culprit finder found no pull request of the train that caused the failure."
      end
      "CI #{@build.id} failed. #{cause} This pull request stays at the head of the merge queue and runs in " \
        "the next train. You do not need to comment `/shipit` again."
    end

    def alone_comment(decision)
      cause = case decision
      when DECISION_SECOND_RED then "This is the second failed train in a row for its pull requests."
      when DECISION_STACK_CI then "The repository checks failed on the combined branch of more than one pull request."
      else "Shipit could not name the pull request that caused the failure."
      end
      "CI #{@build.id} failed. #{cause} This pull request stays in the merge queue and runs alone " \
        "(single mode). You do not need to comment `/shipit` again."
    end
  end
end
