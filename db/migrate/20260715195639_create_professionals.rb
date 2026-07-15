class CreateProfessionals < ActiveRecord::Migration[8.1]
  def change
    create_table :professionals do |t|
      t.string :name, null: false
      t.string :role, null: false
      t.decimal :rate_office, precision: 10, scale: 2, null: false
      t.decimal :rate_field, precision: 10, scale: 2, null: false
      t.string :registration
      t.string :specialties
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :professionals, :active
  end
end
