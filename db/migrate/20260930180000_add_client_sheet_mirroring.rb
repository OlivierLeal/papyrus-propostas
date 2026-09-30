# Precificação espelhando a lista de preços do cliente (PPU): cada item nasce de um item da planilha,
# com a quantidade e a unidade DELE, e a equipe é dimensionada POR UNIDADE (o Ruby multiplica).
# Conversa 65: a PPU pedia 2.994 diárias embarcadas e a equipe estimada pelo escopo tinha 600.
class AddClientSheetMirroring < ActiveRecord::Migration[8.1]
  def change
    change_table :pricing_items, bulk: true do |t|
      t.decimal :client_quantity, precision: 14, scale: 4
      t.string :client_unit
      t.string :client_code
      # { "blob_id", "aba", "celula_preco", "celula_quantidade" } — onde o preço unitário é escrito.
      t.jsonb :client_sheet, null: false, default: {}
    end

    change_table :proposal_professionals, bulk: true do |t|
      t.decimal :man_hours_per_unit, precision: 12, scale: 4
      t.decimal :field_days_per_unit, precision: 12, scale: 4
    end
  end
end
