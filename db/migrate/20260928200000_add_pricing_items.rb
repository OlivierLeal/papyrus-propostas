# Precificação por ITEM, com logística por campo e vários empreendimentos (2026-09-28, a partir da
# planilha real da Papyrus 26098_Newave Energia_BESS: cada item tem equipe, campos de logística e
# custos próprios; a logística leva BDI × impostos; itens comuns são rateados entre empreendimentos).
#
# Só ADITIVA, de propósito: não apaga coluna nenhuma e não recalcula total nenhum. As colunas antigas
# (logistics_days, vehicles_count, fuel_total, price_breakdown, proposal_professionals.stage) ficam
# no banco sem uso até uma migração separada, depois de validado em produção. O `down` desfaz tudo.
#
# Cópia dos dados: as etapas viram itens; linhas sem etapa vão pro item "Execução do serviço"; a
# logística única antiga (dias > 0) vira UM campo no item com mais diárias. Totais gravados não
# mudam até alguém salvar a precificação de novo.
class AddPricingItems < ActiveRecord::Migration[8.1]
  DEFAULT_ITEM = "Execução do serviço"

  def up
    create_table :pricing_enterprises do |t|
      t.references :project_pricing, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :pricing_items do |t|
      t.references :project_pricing, null: false, foreign_key: true
      t.references :pricing_enterprise, foreign_key: { on_delete: :nullify }
      t.string :name, null: false
      t.integer :position, null: false, default: 0
      t.jsonb :costs, null: false, default: []
      t.timestamps
    end

    create_table :field_campaigns do |t|
      t.references :pricing_item, null: false, foreign_key: { on_delete: :cascade }
      t.string :description, null: false
      t.integer :people, null: false, default: 1
      t.decimal :days, precision: 8, scale: 2, null: false, default: 1
      t.decimal :travel_days, precision: 8, scale: 2, null: false, default: 0
      t.integer :vehicles, null: false, default: 1
      t.string :vehicle_type, null: false, default: "carro"
      t.integer :tolls, null: false, default: 0
      t.integer :washes, null: false, default: 0
      t.integer :uber_trips, null: false, default: 0
      t.decimal :mateiro_days, precision: 8, scale: 2, null: false, default: 0
      t.integer :epi_count, null: false, default: 0
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    add_reference :proposal_professionals, :pricing_item, foreign_key: { on_delete: :nullify }

    change_table :project_pricings, bulk: true do |t|
      t.decimal :rental_4x4_per_day, precision: 10, scale: 2, null: false, default: 750
      t.decimal :toll_price, precision: 10, scale: 2, null: false, default: 30
      t.decimal :wash_price, precision: 10, scale: 2, null: false, default: 80
      t.decimal :uber_price, precision: 10, scale: 2, null: false, default: 70
      t.decimal :mateiro_per_day, precision: 10, scale: 2, null: false, default: 250
      t.decimal :epi_price, precision: 10, scale: 2, null: false, default: 2700
      t.decimal :daily_km, precision: 10, scale: 2, null: false, default: 100
      t.string :common_split, null: false, default: "equal"
      t.string :price_presentation, null: false, default: "total"
    end

    # Valores unitários da planilha da Papyrus como padrão das propostas NOVAS (as existentes
    # mantêm o que já têm gravado).
    change_column_default :project_pricings, :rental_per_day, from: 0, to: 250
    change_column_default :project_pricings, :lodging_per_person_per_night, from: 0, to: 220
    change_column_default :project_pricings, :meal_per_person_per_day, from: 0, to: 100
    change_column_default :project_pricings, :fuel_price_per_liter, from: 6.2, to: 8
    change_column_default :project_pricings, :vehicle_consumption_km_per_liter, from: 10, to: 8

    copy_data
  end

  def down
    change_column_default :project_pricings, :rental_per_day, from: 250, to: 0
    change_column_default :project_pricings, :lodging_per_person_per_night, from: 220, to: 0
    change_column_default :project_pricings, :meal_per_person_per_day, from: 100, to: 0
    change_column_default :project_pricings, :fuel_price_per_liter, from: 8, to: 6.2
    change_column_default :project_pricings, :vehicle_consumption_km_per_liter, from: 8, to: 10

    change_table :project_pricings, bulk: true do |t|
      t.remove :rental_4x4_per_day, :toll_price, :wash_price, :uber_price, :mateiro_per_day,
        :epi_price, :daily_km, :common_split, :price_presentation
    end
    remove_reference :proposal_professionals, :pricing_item, foreign_key: true
    drop_table :field_campaigns
    drop_table :pricing_items
    drop_table :pricing_enterprises
  end

  private

    def copy_data
      select_all("SELECT id, logistics_days, vehicles_count, price_breakdown FROM project_pricings").each do |pricing|
        id = pricing["id"]
        lines = select_all("SELECT id, stage, field_days FROM proposal_professionals WHERE project_pricing_id = #{id} ORDER BY id").to_a
        stage_of = ->(line) { line["stage"].to_s.strip.presence || DEFAULT_ITEM }
        names = lines.map(&stage_of).uniq
        names = [ DEFAULT_ITEM ] if names.empty?

        item_ids = names.each_with_index.to_h { |name, position| [ name, insert_item(id, name, position) ] }
        lines.each do |line|
          execute("UPDATE proposal_professionals SET pricing_item_id = #{item_ids.fetch(stage_of.call(line))} WHERE id = #{line['id']}")
        end

        days = pricing["logistics_days"].to_i
        next unless days.positive?

        field_days = names.index_with { |name| lines.select { |line| stage_of.call(line) == name }.sum { |line| line["field_days"].to_f } }
        people = [ lines.count { |line| line["field_days"].to_f.positive? }, 1 ].max
        execute(<<~SQL)
          INSERT INTO field_campaigns (pricing_item_id, description, people, days, travel_days, vehicles, vehicle_type, created_at, updated_at)
          VALUES (#{item_ids.fetch(field_days.max_by { |_, value| value }.first)}, 'Campo', #{people}, #{days}, 0,
                  #{[ pricing['vehicles_count'].to_i, 1 ].max}, 'carro', NOW(), NOW())
        SQL
      end

      execute("UPDATE project_pricings SET price_presentation = 'itens' WHERE price_breakdown")
    end

    def insert_item(pricing_id, name, position)
      select_value(<<~SQL)
        INSERT INTO pricing_items (project_pricing_id, name, position, created_at, updated_at)
        VALUES (#{pricing_id}, #{connection.quote(name)}, #{position}, NOW(), NOW()) RETURNING id
      SQL
    end
end
