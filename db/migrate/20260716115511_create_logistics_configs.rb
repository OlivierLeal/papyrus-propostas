class CreateLogisticsConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :logistics_configs do |t|
      t.string :name, null: false
      t.decimal :rental_per_day, precision: 10, scale: 2, null: false
      t.decimal :fuel_price_per_liter, precision: 10, scale: 2, null: false
      t.decimal :lodging_per_day, precision: 10, scale: 2, null: false
      t.decimal :meal_per_day, precision: 10, scale: 2, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :logistics_configs, :active
  end
end
