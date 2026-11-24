# frozen_string_literal: true

module Shipit
  # Shows how often the culprit finder named the right pull request of a red train. The check is
  # the next CI of the pull request that the finder named: red alone confirms the finder, green
  # shows that the finder was wrong. An answer below the threshold of the stack counts too, so
  # the report also works while Shipit only stores the answers.
  class CulpritFinderReport
    CONFIRMED = 'confirmed'
    WRONG = 'wrong'
    UNKNOWN = 'unknown'

    Row = Struct.new(:build, :culprit, :confidence, :removed, :next_build, :verdict, keyword_init: true)

    def initialize(since: 7.days.ago, environment: nil, min_confidence: 0)
      @since = since
      @environment = environment
      @min_confidence = min_confidence
    end

    def trains
      @trains ||= begin
        scope = PredictiveBuild.where.not(train_decision: nil).where('predictive_builds.created_at >= ?', @since)
        scope = scope.joins(:pipeline).where(pipelines: { environment: @environment }) if @environment
        scope.order(:id).to_a
      end
    end

    def rows
      @rows ||= trains.map { |build| row(build) }.compact
    end

    def summary
      verdicts = rows.group_by(&:verdict).transform_values(&:size)
      checked = verdicts.fetch(CONFIRMED, 0) + verdicts.fetch(WRONG, 0)
      {
        red_trains: trains.size,
        decisions: trains.group_by(&:train_decision).transform_values(&:size),
        named: rows.size,
        removed: rows.count(&:removed),
        confirmed: verdicts.fetch(CONFIRMED, 0),
        wrong: verdicts.fetch(WRONG, 0),
        unknown: verdicts.fetch(UNKNOWN, 0),
        accuracy: checked.zero? ? nil : (verdicts.fetch(CONFIRMED, 0).to_f / checked).round(2),
      }
    end

    def to_s
      lines = ["Culprit finder, red trains since #{@since.to_date}#{" on #{@environment}" if @environment}"]
      summary.each { |key, value| lines << "#{key}: #{value.nil? ? '-' : value}" }
      rows.each do |row|
        culprit = "#{row.culprit.stack.github_repo_name}##{row.culprit.number}"
        next_ci = row.next_build ? "CI #{row.next_build.id} #{row.next_build.status}" : 'no CI after it'
        action = row.removed ? 'removed' : 'recorded only'
        lines << "CI #{row.build.id}: #{culprit}, confidence #{row.confidence}, #{action}, #{next_ci} => #{row.verdict}"
      end
      lines.join("\n")
    end

    private

    def row(build)
      answer = JSON.parse(build.culprit_finder_answer.presence || '{}')
      confidence = Float(answer['confidence'], exception: false)
      culprit = build.culprit_merge_request || RedTrain.named_in(answer, merge_requests_of(build))
      return if culprit.nil? || confidence.to_f < @min_confidence

      next_build = next_build_of(culprit, build)
      Row.new(
        build: build,
        culprit: culprit,
        confidence: confidence,
        removed: build.culprit_merge_request.present?,
        next_build: next_build,
        verdict: verdict(next_build),
      )
    end

    def merge_requests_of(build)
      build.predictive_branches.flat_map { |branch| branch.predictive_merge_requests.map(&:merge_request) }.uniq
    end

    def next_build_of(merge_request, build)
      PredictiveBuild.joins(predictive_branches: :predictive_merge_requests)
        .where(predictive_merge_requests: { merge_request_id: merge_request.id })
        .where('predictive_builds.id > ?', build.id)
        .where(status: %w(completed failed))
        .order(:id).first
    end

    # A green CI clears the pull request, alone or in a train. A red CI blames it only when it ran alone.
    def verdict(next_build)
      return UNKNOWN unless next_build
      return WRONG if next_build.completed?

      alone = PredictiveMergeRequest.where(predictive_branch: next_build.predictive_branches).count == 1
      alone ? CONFIRMED : UNKNOWN
    end
  end
end
