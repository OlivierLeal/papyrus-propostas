class CreateProjectConflicts < ActiveRecord::Migration[8.1]
  def change
    create_table :project_conflicts do |t|
      t.references :conversation, null: false, foreign_key: true

      # Campo em que os documentos discordam (ProjectFinding::FIELDS).
      t.string :field, null: false
      # Uma frase descrevendo a divergência, para o consultor entender sem abrir os documentos.
      t.text :summary, null: false

      # open | resolved | dismissed. Divergência não resolvida NÃO bloqueia a geração do
      # documento — vira ressalva no texto (decisão de escopo desta rodada).
      t.string :status, null: false, default: "open"
      t.text :resolution_note
      t.references :resolved_by, foreign_key: { to_table: :users }
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :project_conflicts, [ :conversation_id, :status ]
  end
end
