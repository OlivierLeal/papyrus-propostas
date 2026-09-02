class AddReferencesToGeneralChatsGeneralToolCallsAndGeneralMessages < ActiveRecord::Migration[8.1]
  def change
    add_reference :general_chats, :model, foreign_key: true
    add_reference :general_tool_calls, :general_message, null: false, foreign_key: true
    add_reference :general_messages, :general_chat, null: false, foreign_key: true
    add_reference :general_messages, :model, foreign_key: true
    add_reference :general_messages, :general_tool_call, foreign_key: true
  end
end
