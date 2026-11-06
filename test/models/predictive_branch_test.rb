# frozen_string_literal: true
require 'test_helper'

module Shipit
  class PredictiveBranchTest < ActiveSupport::TestCase
    setup do
      @stack = shipit_stacks(:shipit)
      pipeline = Pipeline.create!(name: 'shipit-test', environment: 'production')
      build = PredictiveBuild.create!(pipeline: pipeline, branch: 'PREDICTIVE-BRANCH-1')
      @branch = PredictiveBranch.create!(
        predictive_build: build,
        branch: build.branch,
        stack: @stack,
        stack_commit: shipit_commits(:fifth),
      )
    end

    test "#target_branch_moved? is true when the target has commits the predictive branch does not have" do
      Shipit.github.api.expects(:compare).with('shopify/shipit-engine', 'master', 'PREDICTIVE-BRANCH-1')
        .returns(stub(behind_by: 2))

      assert_predicate @branch, :target_branch_moved?
    end

    test "#target_branch_moved? is false when the predictive branch contains the target" do
      Shipit.github.api.stubs(:compare).returns(stub(behind_by: 0))

      refute_predicate @branch, :target_branch_moved?
    end

    test "#target_branch_moved? is false when GitHub cannot compare" do
      Shipit.github.api.stubs(:compare).raises(Octokit::NotFound)

      refute_predicate @branch, :target_branch_moved?
    end
  end
end
