# study_templates saiu (2026-09, pedido do consultor: a Papyrus não ia manter um "menu" de equipe
# por tipo de estudo). A IA monta a equipe direto do cadastro de profissionais — ver
# Proposal#build_with_ai_suggested_team!.
class DropStudyTemplates < ActiveRecord::Migration[8.1]
  def change
    drop_table :study_templates do |t|
      t.references :study_type, null: false, foreign_key: true
      t.references :professional, null: false, foreign_key: true
      t.string :deliverable_name, null: false
      t.decimal :man_hours_default, precision: 8, scale: 2, default: "0.0", null: false
      t.decimal :field_days_default, precision: 8, scale: 2, default: "0.0", null: false
      t.timestamps
      t.index [ :study_type_id, :professional_id, :deliverable_name ], unique: true, name: "index_study_templates_on_type_professional_deliverable"
    end
  end
end
