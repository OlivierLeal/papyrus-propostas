class AddDomainFieldsToConversations < ActiveRecord::Migration[8.1]
  def change
    add_reference :conversations, :user, null: false, foreign_key: true
    add_column :conversations, :client_name, :string, null: false
    add_column :conversations, :status, :string, null: false, default: "setup"
    add_reference :conversations, :study_type, null: false, foreign_key: true
    add_column :conversations, :setup_completed_at, :datetime

    add_index :conversations, :status
  end
end
