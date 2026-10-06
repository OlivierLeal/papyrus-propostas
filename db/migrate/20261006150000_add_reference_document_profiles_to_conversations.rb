# O que é cada documento do campo TR (2026-10, proposta 34: o "TR" era a portaria da licença).
# { blob_id => { "tipo", "numero", "anexar", "motivo" } }, preenchido pelo ProcessTrJob (a IA lê o
# documento) — é o que dá o título do anexo ("ANEXO I – PORTARIA Nº 25.288/2022") e decide se ele
# entra (minuta, condições de compra e edital não entram).
class AddReferenceDocumentProfilesToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :reference_document_profiles, :jsonb, null: false, default: {}
  end
end
