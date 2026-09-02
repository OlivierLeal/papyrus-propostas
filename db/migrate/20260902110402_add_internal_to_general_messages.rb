class AddInternalToGeneralMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :general_messages, :internal, :boolean, null: false, default: false
  end
end
