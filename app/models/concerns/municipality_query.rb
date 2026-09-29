# Município digitado na tela ("Remanso/BA") pra quem tem belongs_to :ibge_municipality
# (ProjectPricing = local do projeto, FieldCampaign = local do campo). Em branco limpa; nome que não
# casa (ou ambíguo sem UF) vira erro de validação em vez de sumir em silêncio.
module MunicipalityQuery
  extend ActiveSupport::Concern

  included do
    belongs_to :ibge_municipality, optional: true
    validate :municipality_query_found
  end

  def municipality_query
    @municipality_query || ibge_municipality&.label
  end

  def municipality_query=(text)
    @municipality_query = text.to_s.strip
    @municipality_not_found = false
    return self.ibge_municipality = nil if @municipality_query.blank?
    return if ibge_municipality&.label == @municipality_query

    self.ibge_municipality = IbgeMunicipality.lookup(@municipality_query)
    @municipality_not_found = ibge_municipality.nil?
    # Registro aninhado sem mudança não é validado pelo pai (autosave) — marca como alterado pra o
    # erro aparecer em vez de o texto digitado sumir em silêncio.
    ibge_municipality_id_will_change! if @municipality_not_found
  end

  private
    def municipality_query_found
      return unless @municipality_not_found

      errors.add(:base, "Município \"#{@municipality_query}\" não encontrado#{municipality_query_context} — use Nome/UF, ex.: Remanso/BA")
    end

    def municipality_query_context = ""
end
