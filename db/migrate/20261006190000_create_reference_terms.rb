# Biblioteca de TRs da Papyrus (2026-10): TRs, roteiros de conteúdo mínimo e instruções normativas
# de órgãos (INEMA, CPRH, ADEMA, SEDUR Camaçari…) que a Papyrus juntou. A busca do TR do estudo
# (FindTermOfReferenceJob) olha aqui antes do CAL e da internet; aceito no card, o arquivo daqui
# vira o anexo da proposta. O arquivo original fica no banco (file_data) pra o SQL de produção
# (script/reference_terms/export.rb) levar tudo, sem depender do Active Storage.
class CreateReferenceTerms < ActiveRecord::Migration[8.1]
  def change
    create_table :reference_terms do |t|
      t.string :sha256, null: false, index: { unique: true }
      t.string :status, null: false, default: "active" # active | ignored (não é TR)
      t.string :title, null: false
      t.string :document_type
      t.string :number
      t.string :organ
      t.string :uf
      t.string :municipality
      t.string :study_types, array: true, default: []
      t.string :activities
      t.text :summary
      t.text :notes
      t.string :source_path
      t.string :filename, null: false
      t.string :content_type
      t.binary :file_data
      t.text :full_text
      t.text :descriptor
      t.vector :embedding, limit: 1024
      t.string :embedding_model
      t.timestamps
    end
    add_reference :term_of_reference_candidates, :reference_term, foreign_key: true
  end
end
