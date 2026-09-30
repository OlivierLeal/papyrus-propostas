# Preenchimento de planilha de preço do cliente (PPU, DFP etc.) — ver SpreadsheetFill.
class CreateSpreadsheetFills < ActiveRecord::Migration[8.1]
  def change
    create_table :spreadsheet_fills do |t|
      t.references :conversation, null: false, foreign_key: true
      t.references :source_blob, null: false, foreign_key: { to_table: :active_storage_blobs }
      t.string :status, null: false, default: "processing"
      t.text :instructions
      t.jsonb :plan, null: false, default: {}
      t.jsonb :report, null: false, default: {}
      t.text :error
      # Disparado sozinho na geração da proposta (sem card quando a planilha não é formulário).
      t.boolean :automatic, null: false, default: false
      # O consultor mandou preencher uma planilha que a IA tinha classificado como referência.
      t.boolean :forced, null: false, default: false
      # Digest dos fatos que o preenchimento usou — mudou, a planilha está desatualizada.
      t.string :facts_digest
      t.timestamps
    end
    add_index :spreadsheet_fills, %i[conversation_id source_blob_id]

    # Parte do valor da hora-homem/diária que é encargo social (fração, ex.: 0.8 = 80%). Planilhas
    # de formação de preço pedem salário e encargos separados; sem isso, o valor vai cheio.
    add_column :professionals, :social_charges_percent, :decimal, precision: 6, scale: 4
  end
end
