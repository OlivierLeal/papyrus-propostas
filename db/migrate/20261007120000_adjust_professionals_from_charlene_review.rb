# Ajustes de cadastro pedidos pela Charlene na revisão da PTC26047 (2026-10-07, grupo "IA Propostas
# Papyrus"). Só dados; idempotente por nome. Os valores continuam editáveis em Configurações.
class AdjustProfessionalsFromCharleneReview < ActiveRecord::Migration[8.1]
  SUPPORT = [ "Carolene Marchant", "Yuri Alves Bezerra" ].freeze # apoio da operação: hora só com produto
  FAUNA_BIOLOGISTS = [ "Ícaro Menezes", "Igor Silva Andrade", "Maria Nogueira", "Enée G. Pereira" ].freeze

  def up
    execute <<~SQL
      UPDATE professionals SET cost_in_bdi = TRUE, updated_at = NOW()
      WHERE name IN (#{SUPPORT.map { |name| quote(name) }.join(', ')});

      UPDATE professionals SET rate_daily = 380, updated_at = NOW()
      WHERE name IN (#{FAUNA_BIOLOGISTS.map { |name| quote(name) }.join(', ')});

      INSERT INTO professionals (name, role, rate_man_hour, rate_daily, registration, specialties, active,
                                 always_included, cost_in_bdi, technical_team, created_at, updated_at)
      SELECT 'Auxiliar de Campo', 'Auxiliar de Campo', 25, 200, NULL,
             'Apoio às campanhas de campo (mateiro/auxiliar).', TRUE, FALSE, FALSE, FALSE, NOW(), NOW()
      WHERE NOT EXISTS (SELECT 1 FROM professionals WHERE name = 'Auxiliar de Campo');
    SQL

    # A diária mudou por SQL: recalcula as propostas abertas, como o callback do cadastro faria.
    Professional.reset_column_information
    Professional.where(name: FAUNA_BIOLOGISTS).find_each { |professional| professional.send(:recalculate_open_pricings) }
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def quote(value) = connection.quote(value)
end
