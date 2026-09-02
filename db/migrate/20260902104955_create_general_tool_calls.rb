class CreateGeneralToolCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :general_tool_calls do |t|
      t.string :tool_call_id, null: false
      t.string :name, null: false
      t.text :thought_signature

      t.json :arguments, default: {}

      t.timestamps
    end

    add_index :general_tool_calls, :tool_call_id, unique: true
    add_index :general_tool_calls, :name
  end
end
