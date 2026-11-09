# frozen_string_literal: true
module PredictiveBuildHelper
  # A predictive build that tests merge_request, with the rows that reference the stack:
  # branch, predictive merge request, CI job status, branch task and its output.
  def put_in_predictive_build(merge_request)
    stack = merge_request.stack
    pipeline = Shipit::Pipeline.create!(name: 'shipit-test', environment: 'production')
    build = Shipit::PredictiveBuild.create!(pipeline: pipeline, branch: 'PREDICTIVE-BRANCH-1')
    branch = Shipit::PredictiveBranch.create!(
      predictive_build: build,
      branch: build.branch,
      stack: stack,
      stack_commit: stack.commits.last,
    )
    Shipit::PredictiveMergeRequest.create!(merge_request: merge_request, predictive_branch: branch, head: merge_request.head)
    Shipit::CiJobsStatus.create!(predictive_branch_id: branch.id, name: 'unit_test', status: :running, link: 'https://ci')
    task = branch.predictive_branch_tasks.create!(stack_id: stack.id, predictive_task_type: 'run', allow_concurrency: true)
    task.write("running\n")
    branch
  end
end
