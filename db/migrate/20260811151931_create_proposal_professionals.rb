class CreateProposalProfessionals < ActiveRecord::Migration[8.1]
  def change
    create_table :proposal_professionals do |t|
      t.references :project_pricing, null: false, foreign_key: true
      t.references :professional, null: false, foreign_key: true
      t.string :deliverable_name, null: false
      t.decimal :hours_office, precision: 8, scale: 2, null: false, default: 0
      t.decimal :hours_field, precision: 8, scale: 2, null: false, default: 0
      t.decimal :subtotal, precision: 12, scale: 2, null: false, default: 0

      t.timestamps
    end
  end
end
