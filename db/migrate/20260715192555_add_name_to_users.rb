class AddNameToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :name, :string
    execute "UPDATE users SET name = email_address WHERE name IS NULL"
    change_column_null :users, :name, false
  end

  def down
    remove_column :users, :name
  end
end
