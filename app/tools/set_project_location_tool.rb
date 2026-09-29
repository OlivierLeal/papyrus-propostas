# Local do projeto (ou de um campo) pelo chat (2026-09-29, pedido do consultor: "alguns casos não
# têm KMZ, mas o ET diz o local ou o consultor diz no chat — a IA tem que interpretar e aplicar,
# também pra atualização"). A IA INTERPRETA o texto ("fazenda na zona rural de Remanso, norte da
# Bahia") e passa município + UF; quem resolve o lugar é o sistema (IbgeMunicipality.lookup, sem
# aceitar ambiguidade), e quem calcula distância/combustível é o motor (ProjectPricing#
# suggest_logistics!, FieldCampaign) — a IA nunca informa km nem valor.
#
# Sem campo: vira achado "municipios" de origem "consultor" (a fonte de mais autoridade no
# DestinationResolver, então vale mesmo antes de a proposta existir) e, com proposta, grava em
# project_pricings.ibge_municipality e refaz a logística. Com campo: só aquele campo muda de local.
class SetProjectLocationTool < RubyLLM::Tool
  description <<~DESC
    Define o local (município) do projeto, ou de um campo específico da precificação, usado pra
    calcular distância, dias de viagem, combustível e buscar hospedagem. Use quando:
    - não há KMZ e o local aparece no ET/TR ou em documento complementar só em texto;
    - o consultor informar ou CORRIGIR o local no chat ("o projeto é em Remanso", "o campo de fauna
      é perto de Sento Sé");
    - o bloco [ESTADO ATUAL DA PROPOSTA] mostrar "Local da logística: não definido" e você souber
      o local pelos documentos ou pela conversa.
    Interprete o texto e passe o MUNICÍPIO com a UF (ex.: "Remanso/BA") — para uma fazenda ou
    localidade rural, o município onde ela fica. Nunca invente: se não souber o município ou a UF
    com segurança, pergunte ao consultor. Não informe distância nem valor — o sistema calcula.
  DESC

  param :municipio, desc: "Município e UF, no formato \"Nome/UF\" (ex.: \"Remanso/BA\")"
  param :campo, required: false,
    desc: "Descrição do campo da precificação (ex.: \"Fauna\") quando o local vale só pra ele. " \
          "Deixe vazio pra definir o local do projeto inteiro."

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute(municipio:, campo: nil)
    municipality = IbgeMunicipality.lookup(municipio)
    return { error: not_found_message(municipio) }.to_json unless municipality

    proposal = @conversation.proposal
    return { error: "Esta proposta já foi aprovada — reabra a precificação pra mudar o local." }.to_json if proposal&.status == "approved"

    campo.present? ? set_campaign(proposal, municipality, campo) : set_project(proposal, municipality)
  rescue StandardError => e
    Rails.logger.error("SetProjectLocationTool falhou na conversa #{@conversation.id}: #{e.class} #{e.message}")
    { error: "Não consegui definir o local agora. Tente novamente em instantes." }.to_json
  end

  private
    def set_project(proposal, municipality)
      @conversation.project_findings.create!(field: "municipios", value: municipality.label, nature: "fato",
        source_kind: "consultor", excerpt: "Local do projeto definido no chat.")
      return { success: true, municipio: municipality.label,
               mensagem: "Local registrado. A logística será calculada quando a precificação for criada." }.to_json unless proposal&.project_pricing

      pricing = proposal.project_pricing
      pricing.update!(ibge_municipality: municipality)
      pricing.suggest_logistics!
      pricing.reload
      { success: true, municipio: municipality.label, distancia_km: pricing.distance_km.to_f,
        tempo_de_viagem: duration_label(pricing.travel_hours), total_atualizado: pricing.total_value.to_f,
        mensagem: "Local do projeto atualizado e logística recalculada. Campos com município próprio não mudam." }.to_json
    end

    def set_campaign(proposal, municipality, description)
      return { error: "A precificação ainda não existe — sem campos pra ajustar. Defina o local do projeto inteiro (sem campo)." }.to_json unless proposal&.project_pricing

      pricing = proposal.project_pricing
      campaigns = FieldCampaign.joins(:pricing_item).where(pricing_items: { project_pricing_id: pricing.id }).to_a
      key = IbgeMunicipality.normalize(description)
      matches = campaigns.select { |campaign| IbgeMunicipality.normalize(campaign.description).include?(key) }
      unless matches.size == 1
        names = campaigns.map { |campaign| "\"#{campaign.description}\"" }.join(", ")
        return { error: "#{matches.empty? ? 'Nenhum' : 'Mais de um'} campo corresponde a \"#{description}\". Campos: #{names.presence || 'nenhum'}." }.to_json
      end

      campaign = matches.first
      campaign.update!(ibge_municipality: municipality)
      pricing.recalculate!
      { success: true, campo: campaign.description, municipio: municipality.label,
        distancia_km: campaign.distance_km.to_f, dias_de_viagem: campaign.travel_days.to_f,
        total_atualizado: pricing.reload.total_value.to_f,
        mensagem: "Local do campo atualizado. A hospedagem escolhida antes (se era da busca) foi descartada — busque de novo na Tela de Precificação." }.to_json
    end

    # Já formatado ("7h12") — a IA errava a conversão de 7,2h (escreveu "7h20").
    def duration_label(hours)
      minutes = (hours.to_f * 60).round
      "#{minutes / 60}h#{(minutes % 60).to_s.rjust(2, '0')}"
    end

    def not_found_message(text)
      name = text.to_s.split(%r{\s*[/,\-–]\s*}).first.to_s
      key = IbgeMunicipality.normalize(name)
      candidates = IbgeMunicipality.where("lower(name) = lower(?)", name).limit(10).map(&:label)
      candidates = IbgeMunicipality.pluck(:name, :uf).select { |n, _| IbgeMunicipality.normalize(n) == key }.first(10).map { |n, uf| "#{n}/#{uf}" } if candidates.empty?
      if candidates.size > 1
        "\"#{text}\" é ambíguo — existe em mais de um estado: #{candidates.join(', ')}. Confirme a UF com o consultor."
      else
        "Município \"#{text}\" não encontrado no IBGE. Confira o nome e a UF (formato \"Nome/UF\")."
      end
    end
end
