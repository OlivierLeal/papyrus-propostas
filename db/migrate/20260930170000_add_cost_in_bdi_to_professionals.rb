# Diretoria (Charlene, Ricardo, Sara) não cobra hora-homem nem diária: o custo delas já está no BDI
# (Charlene, 2026-09-30). Com a marca, os valores ficam zerados (Professional#zero_rates_when_in_bdi)
# e as propostas abertas são recalculadas pelo callback de sempre (recalculate_open_pricings).
class AddCostInBdiToProfessionals < ActiveRecord::Migration[8.1]
  NAMES = [ "Charlene Luz", "Ricardo Hortélio", "Sara Marçal" ].freeze

  def up
    add_column :professionals, :cost_in_bdi, :boolean, null: false, default: false
    Professional.reset_column_information
    Professional.where(name: NAMES).find_each { |professional| professional.update!(cost_in_bdi: true) }
  end

  def down
    remove_column :professionals, :cost_in_bdi
  end
end
