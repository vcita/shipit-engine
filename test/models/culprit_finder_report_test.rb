# frozen_string_literal: true
require 'test_helper'

module Shipit
  class CulpritFinderReportTest < ActiveSupport::TestCase
    setup do
      @stack = shipit_stacks(:shipit)
      @pipeline = Pipeline.create!(name: 'shipit-test', environment: 'integration')
      @culprit = shipit_merge_requests(:shipit_pending)
      @other = shipit_merge_requests(:shipit_pending_unmergeable)
      @train = build('failed', [@culprit, @other], mode: Pipeline::MERGE_MODE_TRAIN,
                     train_decision: RedTrain::DECISION_CULPRIT_REJECTED, culprit_merge_request: @culprit,
                     culprit_finder_answer: { culprit_pr: @culprit.number, confidence: 0.9 }.to_json)
    end

    test "a culprit that fails again alone confirms the finder" do
      build('failed', [@culprit])

      assert_equal [CulpritFinderReport::CONFIRMED], report.rows.map(&:verdict)
      assert_equal 1.0, report.summary[:accuracy]
    end

    test "a culprit that passes in its next CI shows a wrong answer" do
      build('completed', [@culprit])

      row = report.rows.first
      assert_equal CulpritFinderReport::WRONG, row.verdict
      assert_equal 0.9, row.confidence
      assert_equal 0.0, report.summary[:accuracy]
    end

    test "a culprit that fails again in a train, or has no later CI, is unknown" do
      assert_equal [CulpritFinderReport::UNKNOWN], report.rows.map(&:verdict)

      build('failed', [@culprit, @other])

      assert_equal [CulpritFinderReport::UNKNOWN], report.rows.map(&:verdict)
      assert_nil report.summary[:accuracy]
    end

    test "a canceled CI of the culprit does not count" do
      build('canceled', [@culprit])
      build('failed', [@culprit])

      assert_equal [CulpritFinderReport::CONFIRMED], report.rows.map(&:verdict)
    end

    test "the summary counts every red train by its decision" do
      build('failed', [@other], mode: Pipeline::MERGE_MODE_TRAIN, train_decision: RedTrain::DECISION_LOW_CONFIDENCE)

      summary = report.summary
      assert_equal 2, summary[:red_trains]
      assert_equal({ 'culprit_rejected' => 1, 'low_confidence' => 1 }, summary[:decisions])
    end

    test "the report keeps to one environment and to the days asked" do
      assert_empty CulpritFinderReport.new(environment: 'production').rows
      assert_empty CulpritFinderReport.new(since: 1.minute.from_now).rows
      assert_match(/CI #{@train.id}: .*##{@culprit.number}, confidence 0.9, removed, no CI after it => unknown/, report.to_s)
    end

    test "an answer that Shipit only stored gets a verdict too" do
      recorded = recorded_train(culprit_pr: @other.number, confidence: 0.9)
      build('failed', [@other])

      row = report.rows.last
      assert_equal [recorded, @other, false], [row.build, row.culprit, row.removed]
      assert_equal CulpritFinderReport::CONFIRMED, row.verdict
      assert_equal({ named: 2, removed: 1 }, report.summary.slice(:named, :removed))
      assert_match(/CI #{recorded.id}: .*##{@other.number}, confidence 0.9, recorded only, CI \d+ failed => confirmed/, report.to_s)
    end

    test "a stored answer that names no pull request of its train has no row" do
      recorded_train(culprit_pr: nil, confidence: 0.9)
      recorded_train(culprit_pr: 999_999, confidence: 0.9)
      recorded_train(culprit_pr: @other.number, culprit_repo: 'another-repo', confidence: 0.9)

      assert_equal [@train], report.rows.map(&:build)
    end

    test "min_confidence leaves out the answers below it" do
      recorded_train(culprit_pr: @other.number, confidence: 0.4)

      assert_equal 2, report.rows.size
      assert_equal [@train], CulpritFinderReport.new(environment: 'integration', min_confidence: 0.7).rows.map(&:build)
    end

    private

    def report
      CulpritFinderReport.new(environment: 'integration')
    end

    def recorded_train(answer)
      build('failed', [@culprit, @other], mode: Pipeline::MERGE_MODE_TRAIN,
            train_decision: RedTrain::DECISION_LOW_CONFIDENCE, culprit_finder_answer: answer.to_json)
    end

    def build(status, merge_requests, attributes = {})
      build = PredictiveBuild.create!(pipeline: @pipeline, branch: 'PREDICTIVE-BRANCH-X', status: status, **attributes)
      branch = PredictiveBranch.create!(
        predictive_build: build, branch: build.branch, stack: @stack, stack_commit: shipit_commits(:fifth)
      )
      merge_requests.each do |merge_request|
        PredictiveMergeRequest.create!(merge_request: merge_request, predictive_branch: branch, head: merge_request.head)
      end
      build
    end
  end
end
