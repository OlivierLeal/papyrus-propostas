# Ficha estruturada de cada job do acervo (2026-09-27, avaliação do RAG: a IA buscava "equipe…
# horas homem diárias…" e só recebia trechos de texto corrido; valor e equipe de projetos
# anteriores nunca estavam disponíveis como dado). Uma linha por job, extraída UMA vez por IA a
# partir do que a própria proposta da Papyrus escreveu — transcrição, nunca cálculo — e com vetor
# próprio (descritor do serviço) pra achar os jobs parecidos com a proposta atual.
class CreateJobPrecedents < ActiveRecord::Migration[8.1]
  def change
    create_table :job_precedents do |t|
      t.string :job_number, null: false
      t.string :client_name
      t.integer :year
      t.text :service
      t.string :study_types, array: true, default: []
      t.string :license_acts, array: true, default: []
      t.text :enterprise
      t.string :location
      t.decimal :total_value, precision: 14, scale: 2
      t.string :value_notes
      t.string :duration
      t.jsonb :team, null: false, default: []
      t.jsonb :other_costs, null: false, default: []
      # Da planilha de precificação do job, quando existe (BDI, impostos, logística, observações).
      t.jsonb :pricing_details, null: false, default: {}
      t.boolean :from_spreadsheet, null: false, default: false
      t.text :descriptor
      t.vector :embedding, limit: 1024
      t.string :embedding_model
      t.string :source_documents, array: true, default: []
      t.string :extraction_model
      t.string :status, null: false, default: "ok"
      t.string :error_message
      t.datetime :extracted_at
      t.timestamps
    end
    add_index :job_precedents, :job_number, unique: true
    add_index :job_precedents, :embedding, using: :hnsw, opclass: :vector_cosine_ops
  end
end
