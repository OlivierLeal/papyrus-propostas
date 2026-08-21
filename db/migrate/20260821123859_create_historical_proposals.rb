class CreateHistoricalProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :historical_proposals do |t|
      # Identificação do job (a pasta), não do arquivo: número, cliente e assunto vêm do nome
      # da pasta, que no acervo real é bem mais confiável que o nome de cada documento.
      t.string :job_name, null: false
      t.string :job_number
      t.string :client_name
      t.string :subject

      t.string :source_path, null: false
      t.string :relative_path, null: false
      t.string :filename, null: false
      # Idempotência do pipeline: mesmo conteúdo + mesma regra de corte = não reprocessa.
      t.string :source_sha256, null: false
      t.string :chunker_version, null: false

      # Papel do documento dentro do job (Rag::DocumentClassifier::ROLES). É o que impede a
      # especificação técnica do cliente de ser recuperada como se fosse a voz da Papyrus.
      t.string :role, null: false
      t.string :role_source, null: false

      t.string :status, null: false
      t.integer :page_count, default: 0, null: false
      t.integer :revision
      t.integer :year
      # Revisão antiga ou pasta "Desatualizados": fica registrada, mas fora da busca.
      t.boolean :superseded, default: false, null: false

      t.string :spreadsheet_path
      t.jsonb :pricing_data
      t.text :error_message

      t.timestamps
    end

    add_index :historical_proposals, :source_sha256, unique: true
    add_index :historical_proposals, [ :role, :superseded ]
    add_index :historical_proposals, :job_number
  end
end
