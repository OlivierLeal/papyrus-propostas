# A diária dos biólogos de fauna mudou por SQL (AdjustProfessionalsFromCharleneReview): recalcula as
# propostas abertas que usam esses profissionais, como o callback do cadastro faria. Roda depois de
# AddOwnValuesToProposalProfessionals, porque o cálculo novo usa as colunas que ela cria.
class RecalculateOpenPricingsAfterCharleneReview < ActiveRecord::Migration[8.1]
  def up
    [ Professional, ProposalProfessional, ProjectPricing ].each(&:reset_column_information)
    names = [ "Ícaro Menezes", "Igor Silva Andrade", "Maria Nogueira", "Enée G. Pereira" ]
    Professional.where(name: names).find_each { |professional| professional.send(:recalculate_open_pricings) }
  end

  def down; end
end
