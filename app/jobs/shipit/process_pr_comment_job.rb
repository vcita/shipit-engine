# frozen_string_literal: true
module Shipit
  class ProcessPrCommentJob < BackgroundJob
    queue_as :default

    def perform(params)
      deploy = Deploy.find(params[:task_id])
      status = params[:task_id]
      description = params[:description]
      permalink = params[:permalink]
      deploy.set_deploy_comment_on_pr(status, description, permalink)
    end
  end
end
