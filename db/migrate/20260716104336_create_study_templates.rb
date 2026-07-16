class CreateStudyTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :study_templates do |t|
      t.references :study_type, null: false, foreign_key: true
      t.references :professional, null: false, foreign_key: true
      t.string :deliverable_name, null: false
      t.decimal :hours_office_default, precision: 8, scale: 2, null: false, default: 0
      t.decimal :hours_field_default, precision: 8, scale: 2, null: false, default: 0

      t.timestamps
    end

    add_index :study_templates, [ :study_type_id, :professional_id, :deliverable_name ],
      unique: true, name: "index_study_templates_on_type_professional_deliverable"
  end
end
