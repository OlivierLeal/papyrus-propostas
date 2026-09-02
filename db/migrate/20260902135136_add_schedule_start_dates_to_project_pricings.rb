class AddScheduleStartDatesToProjectPricings < ActiveRecord::Migration[8.1]
  def change
    # Uma data-âncora por tipo de cronograma (ver ScheduleItem) — sempre digitada pelo consultor,
    # nunca sugerida pela IA. Campo escalar direto na tabela, mesmo padrão de distance_km/bdi —
    # não é o caso de payment_schedule/payment_dates= (aquilo resolve N datas para N parcelas de
    # um jsonb array; aqui é só 1 data por tipo).
    add_column :project_pricings, :schedule_papyrus_start_date, :date
    add_column :project_pricings, :schedule_empreendimento_start_date, :date
  end
end
