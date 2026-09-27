# Consulta PRECEDENTES estruturados do acervo (JobPrecedent): de projetos anteriores parecidos,
# quanto custou (valor total escrito na proposta), quanto durou e que equipe foi alocada (função,
# horas-homem, diárias). Complementa search_historical_archive, que devolve TRECHOS de texto —
# aqui vem o dado já organizado (2026-09-27, avaliação do RAG: a IA buscava "equipe… horas homem
# diárias…" em texto corrido e não achava).
#
# Referência, nunca preço (CLAUDE.md seção 1): serve pra dimensionar equipe e ter noção de porte;
# o preço desta proposta continua saindo do motor de precificação.
class SearchProjectPrecedentsTool < RubyLLM::Tool
  description <<~DESC
    Consulta projetos ANTERIORES da Papyrus parecidos com este e devolve, de forma estruturada, o
    que cada proposta antiga registrou: serviço, tipos de estudo, empreendimento, valor total,
    prazo e a EQUIPE alocada (função, horas-homem e diárias de cada um). Use para dimensionar a
    equipe e o esforço desta proposta, ou quando o consultor perguntar "quanto cobramos/que equipe
    usamos em projetos parecidos".

    Sem o parâmetro `busca`, compara com o próprio escopo desta proposta (o que já foi extraído do
    ET/TR). Com `busca`, compara com a descrição dada (ex.: "EIA-RIMA de parque eólico na Bahia").

    Os valores são REFERÊNCIA HISTÓRICA: nunca copie um valor antigo como preço desta proposta nem
    faça conta com ele — quem calcula o preço é o motor de precificação. Datas e escopos mudam;
    diga isso ao consultor ao citar um valor.

    OBRIGATÓRIO: cite a "referencia" de cada projeto que usar.
  DESC

  param :busca, desc: "Descrição do serviço a comparar (opcional; padrão = o escopo desta proposta)", required: false

  def initialize(conversation: nil, finder: nil)
    super()
    @conversation = conversation
    @finder = finder || Rag::PrecedentFinder.new
  end

  def execute(busca: nil)
    descriptor = busca.to_s.strip.presence || @conversation&.service_descriptor
    return { error: "Não há escopo identificado ainda — descreva o serviço em `busca`." }.to_json if descriptor.blank?

    matches = @finder.call(descriptor, limit: 4)
    return { resultados: [], aviso: "Nenhum projeto anterior parecido o bastante no acervo." }.to_json if matches.empty?

    {
      resultados: matches.map { |match| present(match) },
      instrucao: "Cite a 'referencia'. Valores são históricos (ano indicado): referência de porte, nunca preço desta proposta."
    }.to_json
  rescue StandardError => e
    Rails.logger.error("SearchProjectPrecedentsTool falhou: #{e.class} #{e.message}")
    { error: "Não consegui consultar os precedentes agora." }.to_json
  end

  private

  def present(match)
    precedent = match.precedent
    {
      referencia: precedent.reference,
      servico: precedent.service,
      tipos_estudo: precedent.study_types,
      atos: precedent.license_acts,
      empreendimento: precedent.enterprise,
      local: precedent.location,
      ano: precedent.year,
      valor_total: precedent.total_value&.to_f,
      observacao_valor: precedent.value_notes,
      prazo: precedent.duration,
      equipe: precedent.team_members,
      total_horas_homem: precedent.total_man_hours.positive? ? precedent.total_man_hours : nil,
      total_diarias: precedent.total_field_days.positive? ? precedent.total_field_days : nil,
      outros_custos: precedent.other_costs,
      similaridade: match.similarity
    }.compact
  end
end
