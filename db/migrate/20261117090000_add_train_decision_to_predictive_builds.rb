class AddTrainDecisionToPredictiveBuilds < ActiveRecord::Migration[6.0]
  def change
    add_column :predictive_builds, :culprit_finder_answer, :text
    add_column :predictive_builds, :train_decision, :string, limit: 30
    add_column :predictive_builds, :culprit_merge_request_id, :integer
  end
end
