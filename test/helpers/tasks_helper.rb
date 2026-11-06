# frozen_string_literal: true
module TasksHelper
  # commit_deployments reference tasks, so a bare delete_all on tasks breaks the foreign key.
  def delete_tasks(tasks)
    task_ids = tasks.pluck(:id)
    deployment_ids = Shipit::CommitDeployment.where(task_id: task_ids).pluck(:id)
    Shipit::CommitDeploymentStatus.where(commit_deployment_id: deployment_ids).delete_all
    Shipit::CommitDeployment.where(id: deployment_ids).delete_all
    Shipit::Task.where(id: task_ids).delete_all
  end
end
