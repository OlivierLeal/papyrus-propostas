class CreateProjectConflictFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :project_conflict_findings do |t|
      t.references :project_conflict, null: false, foreign_key: true
      t.references :project_finding, null: false, foreign_key: true

      t.timestamps
    end

    add_index :project_conflict_findings, [ :project_conflict_id, :project_finding_id ],
      unique: true, name: "index_conflict_findings_uniqueness"
  end
end
