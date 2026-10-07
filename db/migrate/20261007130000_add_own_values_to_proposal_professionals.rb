# Profissional terceirizado com preço próprio (Charlene, 2026-10: o Wlisses cobrou R$ 5.000 pelo
# diagnóstico + 5 diárias de R$ 350 na proposta dele, e o sistema usava os valores do cadastro).
# Valores DESTA proposta, por linha; em branco vale o cadastro.
class AddOwnValuesToProposalProfessionals < ActiveRecord::Migration[8.1]
  def change
    add_column :proposal_professionals, :fixed_amount, :decimal, precision: 12, scale: 2, null: false, default: 0
    add_column :proposal_professionals, :rate_man_hour_override, :decimal, precision: 10, scale: 2
    add_column :proposal_professionals, :rate_daily_override, :decimal, precision: 10, scale: 2
  end
end
