class AddScheduleKeyPointsToProjectPricings < ActiveRecord::Migration[8.1]
  def change
    # Os ≤6 marcos que a IA elege do cronograma_servico pra o infográfico de linha do tempo
    # (ScheduleTimelineRenderer) — nome + semana 1-based por marco, na mesma chamada de IA que já
    # sugere o cronograma inteiro (Proposal#schedule_suggestion_prompt). Só o Cronograma do
    # Serviço usa; vazio → o infográfico cai no resumo por fase. Mesmo padrão jsonb de
    # external_costs/payment_schedule.
    add_column :project_pricings, :schedule_key_points, :jsonb, default: [], null: false
  end
end
