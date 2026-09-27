# Hora escritório/hora campo → hora-homem (HH) e diária (2026-09, pedido do consultor).
# Profissional passa a ter "valor da hora-homem" e "valor da diária"; a proposta passa a ter
# quantidade de HH e quantidade de diárias. Preço = HH × valor/hora + diárias × valor da diária.
#
# Conversão dos dados existentes:
# - professionals: rate_office → rate_man_hour, rate_field → rate_daily (valores mantidos — o
#   cadastro hoje está todo em 0,00 no seed; quem já digitou taxa real confere em Configurações).
# - proposal_professionals/study_templates: horas de escritório viram HH direto. Horas de campo
#   viram DIÁRIAS (÷ 8, arredondado pra cima em meia diária) — exceto quando campo == escritório,
#   que era só o espelho do campo único "Horas" (hours_sync_controller), aí diárias = 0.
class SwitchToManHoursAndDailyRates < ActiveRecord::Migration[8.1]
  def up
    rename_column :professionals, :rate_office, :rate_man_hour
    rename_column :professionals, :rate_field, :rate_daily

    convert :proposal_professionals, :hours_office, :hours_field, :man_hours, :field_days
    convert :study_templates, :hours_office_default, :hours_field_default, :man_hours_default, :field_days_default
  end

  def down
    rename_column :professionals, :rate_man_hour, :rate_office
    rename_column :professionals, :rate_daily, :rate_field

    revert_convert :proposal_professionals, :hours_office, :hours_field, :man_hours, :field_days
    revert_convert :study_templates, :hours_office_default, :hours_field_default, :man_hours_default, :field_days_default
  end

  private

  def convert(table, office, field, hours, days)
    rename_column table, office, hours
    add_column table, days, :decimal, precision: 8, scale: 2, default: 0, null: false
    execute <<~SQL
      UPDATE #{table}
      SET #{days} = CEIL(#{field} / 8.0 * 2) / 2
      WHERE #{field} > 0 AND #{field} <> #{hours}
    SQL
    remove_column table, field
  end

  def revert_convert(table, office, field, hours, days)
    rename_column table, hours, office
    add_column table, field, :decimal, precision: 8, scale: 2, default: 0, null: false
    execute "UPDATE #{table} SET #{field} = #{days} * 8"
    remove_column table, days
  end
end
