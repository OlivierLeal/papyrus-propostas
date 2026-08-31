class AddAlwaysIncludedToProfessionals < ActiveRecord::Migration[8.1]
  def change
    add_column :professionals, :always_included, :boolean, default: false, null: false
  end
end
