class CreateStudyTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :study_types do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.text :description

      t.timestamps
    end

    add_index :study_types, :code, unique: true
  end
end
