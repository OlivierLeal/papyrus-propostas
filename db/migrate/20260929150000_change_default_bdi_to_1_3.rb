# BDI padrão das propostas NOVAS passa de 1,20 pra 1,30 (2026-09-29, Charlene no grupo: "BDI 1,3;
# impostos e ADM 1,25"). As propostas existentes mantêm o BDI que já têm gravado.
class ChangeDefaultBdiTo13 < ActiveRecord::Migration[8.1]
  def change
    change_column_default :project_pricings, :bdi, from: 1.2, to: 1.3
  end
end
