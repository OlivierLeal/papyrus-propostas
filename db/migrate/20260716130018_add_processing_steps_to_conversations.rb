class AddProcessingStepsToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :processing_steps, :jsonb, null: false, default: {}
  end
end
