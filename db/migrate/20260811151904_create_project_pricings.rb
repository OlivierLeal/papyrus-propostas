class CreateProjectPricings < ActiveRecord::Migration[8.1]
  def change
    create_table :project_pricings do |t|
      t.references :proposal, null: false, foreign_key: true, index: { unique: true }
      t.decimal :bdi, precision: 6, scale: 4, null: false, default: 1.20
      t.decimal :tax_multiplier, precision: 6, scale: 4, null: false, default: 1.25
      t.decimal :distance_km, precision: 10, scale: 2, null: false, default: 0
      t.integer :logistics_days, null: false, default: 0
      t.decimal :rental_per_day, precision: 10, scale: 2, null: false, default: 0
      t.decimal :meal_per_day, precision: 10, scale: 2, null: false, default: 0
      t.decimal :fuel_total, precision: 10, scale: 2, null: false, default: 0
      t.jsonb :external_costs, null: false, default: []
      t.jsonb :payment_schedule, null: false, default: [
        { "label" => "Assinatura do contrato", "percentage" => 30 },
        { "label" => "Protocolo no órgão ambiental", "percentage" => 60 },
        { "label" => "Vistoria", "percentage" => 5 },
        { "label" => "Emissão da licença", "percentage" => 5 }
      ]
      t.decimal :total_value, precision: 12, scale: 2, null: false, default: 0

      t.timestamps
    end
  end
end
