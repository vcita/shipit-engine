# frozen_string_literal: true

module Shipit
  # Shows how often the culprit finder named the right pull request of a red train. The check is
  # the next CI of the pull request that Shipit removed: red alone confirms the finder, green
  # shows that the finder was wrong.
  class CulpritFinderReport
    CONFIRMED = 'confirmed'
    WRONG = 'wrong'
    UNKNOWN = 'unknown'

    Row = Struct.new(:build, :culprit, :confidence, :next_build, :verdict, keyword_init: true)

    def initialize(since: 7.days.ago, environment: nil)
      @since = since
      @environment = environment
    end

    def trains
      @trains ||= begin
        scope = PredictiveBuild.where.not(train_decision: nil).where('predictive_builds.created_at >= ?', @since)
        scope = scope.joins(:pipeline).where(pipelines: { environment: @environment }) if @environment
        scope.order(:id).to_a
      end
    end

    def rows
      @rows ||= trains.select(&:culprit_merge_request).map do |build|
        next_build = next_build_of(build.culprit_merge_request, build)
        Row.new(
          build: build,
          culprit: build.culprit_merge_request,
          confidence: JSON.parse(build.culprit_finder_answer.presence || '{}')['confidence'],
          next_build: next_build,
          verdict: verdict(next_build),
        )
      end
    end

    def summary
      verdicts = rows.group_by(&:verdict).transform_values(&:size)
      checked = verdicts.fetch(CONFIRMED, 0) + verdicts.fetch(WRONG, 0)
      {
        red_trains: trains.size,
        decisions: trains.group_by(&:train_decision).transform_values(&:size),
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
        lines << "CI #{row.build.id}: #{culprit}, confidence #{row.confidence}, #{next_ci} => #{row.verdict}"
      end
      lines.join("\n")
    end

    private

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
