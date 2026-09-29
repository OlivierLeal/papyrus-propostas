# Hospedagem escolhida por campo (2026-09-29, pedido do consultor): cada campo pode ter o próprio
# local (município), a hospedagem escolhida (Stay22, alojamento digitado ou fornecida pelo cliente)
# e o deslocamento diário até a área — que entra no combustível e alonga os dias de campo.
# Tudo aditivo e nulo/zero por padrão: campo existente continua calculando igual.
# project_pricings.ibge_municipality_id: local do projeto informado pelo consultor (tela ou chat,
# SetProjectLocationTool) — vence KMZ e ET em Logistics::DestinationResolver.
class AddLocationAndLodgingToFieldCampaigns < ActiveRecord::Migration[8.1]
  def change
    add_reference :project_pricings, :ibge_municipality, foreign_key: true, null: true

    change_table :field_campaigns, bulk: true do |t|
      t.references :ibge_municipality, foreign_key: true, null: true
      t.decimal :distance_km, precision: 8, scale: 1
      t.decimal :travel_hours, precision: 6, scale: 1

      t.string :lodging_mode
      t.string :lodging_name
      t.string :lodging_city
      t.string :lodging_url
      t.decimal :lodging_price_per_night, precision: 10, scale: 2
      t.float :lodging_lat
      t.float :lodging_lng
      t.jsonb :lodging_options, default: [], null: false
      t.datetime :lodging_searched_at
      t.string :lodging_search_note

      t.decimal :commute_km, precision: 8, scale: 1, default: 0, null: false
      t.decimal :commute_hours, precision: 5, scale: 2, default: 0, null: false
    end
  end
end
