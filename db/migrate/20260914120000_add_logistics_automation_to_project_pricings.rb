class AddLogisticsAutomationToProjectPricings < ActiveRecord::Migration[8.1]
  def change
    # meal_per_day virou "por pessoa" (Logistics::DestinationResolver/ProjectPricing#suggest_
    # logistics! — 2026-09, pedido do consultor pra automatizar distância/combustível/hospedagem)
    # — renomeado pra deixar a mudança de sentido explícita no schema, não escondida atrás do
    # mesmo nome. Efeito colateral aceito: rascunho em andamento com valor digitado sob o sentido
    # antigo (total fixo/dia) recalcula diferente na próxima vez que "Recalcular preço" rodar;
    # proposta já aprovada não é afetada (campos travados, sem recálculo).
    rename_column :project_pricings, :meal_per_day, :meal_per_person_per_day

    # Nº de veículos de campo, estimado a partir do tamanho da equipe em campo
    # (ProjectPricing::PASSENGERS_PER_VEHICLE) — aluguel/dia passa a multiplicar por isto, não
    # mais por 1 fixo.
    add_column :project_pricings, :vehicles_count, :integer, default: 1, null: false

    # Combustível deixa de ser um total digitado à mão — passa a ser calculado a partir da
    # distância (Logistics::MapboxDirections/estimate) × consumo × preço do litro. Os dois abaixo
    # são só o "preço do litro"/"consumo do veículo" que entram nessa conta; continuam editáveis
    # (o consultor ajusta se o preço do combustível mudar), com defaults razoáveis.
    add_column :project_pricings, :fuel_price_per_liter, :decimal, precision: 10, scale: 2, default: "6.20", null: false
    add_column :project_pricings, :vehicle_consumption_km_per_liter, :decimal, precision: 10, scale: 2, default: "10.0", null: false

    # Hospedagem passa a ENTRAR no cálculo automático (antes era só sugestão informativa via
    # Stay22, que nem tem código ainda) — diária média por pessoa em campo, não busca de preço
    # real de hotel.
    add_column :project_pricings, :lodging_per_person_per_night, :decimal, precision: 10, scale: 2, default: "0.0", null: false

    # Duração estimada de viagem (ida, horas) — só informativo/gatilho do limiar de "distância
    # muito longa" (ProjectPricing::LONG_DISTANCE_HOURS_THRESHOLD), não entra em nenhuma conta de
    # preço.
    add_column :project_pricings, :travel_hours, :decimal, precision: 10, scale: 2
  end
end
