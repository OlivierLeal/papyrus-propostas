# Reabrir precificação aprovada (2026-09-27, pedido do consultor: "às vezes aprovo e o cliente
# pede pra mudar algo"). Guarda o último preço aprovado e quem/quando/por que reabriu — o
# rastro da aprovação não some quando a proposta volta a ser editável.
class AddApprovalHistoryToProposals < ActiveRecord::Migration[8.1]
  def change
    add_column :proposals, :approved_at, :datetime
    add_column :proposals, :approved_total, :decimal, precision: 12, scale: 2
    add_column :proposals, :reopened_at, :datetime
    add_reference :proposals, :reopened_by, foreign_key: { to_table: :users }, null: true
    add_column :proposals, :reopen_reason, :string
  end
end
