class AddInternalToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :internal, :boolean, null: false, default: false
  end
end
