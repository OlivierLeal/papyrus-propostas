# Pendências que TRAVAM a geração da proposta (2026-09-30, pedido do consultor: o cliente pulava os
# questionamentos da IA e pedia pra gerar direto — conversa 65). Ver ProjectIssue.
class CreateProjectIssues < ActiveRecord::Migration[8.1]
  def change
    create_table :project_issues do |t|
      t.references :conversation, null: false, foreign_key: true
      t.text :question, null: false
      t.text :impact
      t.string :source, null: false, default: "resumo"
      t.string :status, null: false, default: "open"
      t.text :answer
      t.text :waiver_reason
      t.references :resolved_by, foreign_key: { to_table: :users }
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :project_issues, %i[conversation_id status]
  end
end
