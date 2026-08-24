class CreateProjectFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :project_findings do |t|
      t.references :conversation, null: false, foreign_key: true

      # Campo do menu fechado (ProjectFinding::FIELDS) — a IA escolhe dentro dele, nunca inventa
      # chave nova, mesma regra já usada para tipo de estudo e composição de equipe.
      t.string :field, null: false
      t.text :value, null: false

      # fato | inferencia | sugestao — a separação da seção 9 do documento de arquitetura.
      # Sem ela, uma dedução da IA volta depois indistinguível de algo lido no TR.
      t.string :nature, null: false, default: "fato"

      # De onde veio: tr, complementar, kmz, sistema, consultor. Fontes não valem o mesmo.
      t.string :source_kind, null: false
      # Documento de origem, quando houver um (nulo para sistema/consultor).
      t.references :source_blob, foreign_key: { to_table: :active_storage_blobs }

      # A evidência propriamente dita: o trecho literal e onde ele está no documento.
      t.text :excerpt
      t.string :locator

      # Achado superado pela decisão do consultor continua no banco (auditoria), fora da leitura.
      t.string :status, null: false, default: "active"
      t.references :superseded_by, foreign_key: { to_table: :project_findings }

      t.timestamps
    end

    add_index :project_findings, [ :conversation_id, :field, :status ]
  end
end
