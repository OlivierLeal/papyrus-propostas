# Procura o TR do estudo (Termo de Referência do órgão competente) quando o cliente não mandou um
# (2026-10, Papyrus: "ele deve procurar automaticamente"). Roda sozinho depois do resumo
# (GenerateSummaryJob) e a pedido no chat (FindTermOfReferenceTool, force: true).
#
# A IA só PROCURA (CAL primeiro, internet no que sobrar) e diz o que achou; o Ruby valida e abre um
# card. Quem decide se aquele TR vira o Anexo I é o consultor — anexar o TR errado é caro.
class FindTermOfReferenceJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, force: false)
    conversation = Conversation.find(conversation_id)
    return if conversation.client_term_of_reference?
    return if !force && conversation.term_of_reference_candidates.exists?
    return tell(conversation, "Não tenho onde procurar o TR agora: o CAL e a busca na internet não estão configurados.", force) unless searchable?

    context = context_for(conversation)
    return tell(conversation, "Ainda não sei qual estudo/licença esta proposta exige — sem isso não dá pra procurar o TR do órgão.", force) if context.blank?

    # As primeiras buscas são do sistema, não da IA (medido ao vivo, conversas 65/66: às vezes ela
    # respondia "não achei" sem ter usado ferramenta nenhuma, mesmo com instrução e com reforço).
    # Ela recebe os resultados prontos pra julgar, e continua podendo ler o texto completo e buscar mais.
    seeds = seed_results(conversation)
    conversation.ask_internally(prompt(conversation, context, seeds), hide_response: true, tools: true)
    found = parse(conversation)
    candidate = found && build_candidate(conversation, found)

    if candidate&.save
      candidate.announce!
    else
      tell(conversation, "Procurei o Termo de Referência do órgão no CAL e na internet e não encontrei um que sirva pra este estudo. " \
        "Se a Papyrus tiver o arquivo, mande no chat e diga que é o TR.", force)
    end
  rescue StandardError => e
    Rails.logger.error("FindTermOfReferenceJob falhou para conversa #{conversation_id}: #{e.class} #{e.message}")
  end

  SEED_RESULTS_PER_QUERY = 6

  private

  # Termos montados do que a proposta já sabe: estudo(s), sigla do órgão e a atividade (início da
  # descrição do empreendimento). Cada busca que falha só some da lista.
  def seed_results(conversation)
    findings = conversation.project_findings.active
    studies = conversation.study_types.map(&:name).first(2)
    organ = findings.where(field: "orgao_ambiental").pluck(:value).first.to_s[/\b[A-Z]{3,}\b/]
    activity = findings.where(field: "empreendimento").pluck(:value).first.to_s.split(/[,;(—–-]/).first.to_s.split.first(3).join(" ")
    subjects = (studies.presence || [ activity ]).compact_blank

    cal = subjects.flat_map { |subject| cal_search("termo de referência #{subject}") }.uniq(&:first).first(10)
    web = subjects.flat_map { |subject| web_search([ "termo de referência", subject, activity, organ ].compact_blank.uniq.join(" ")) }.uniq(&:first).first(10)
    { library: library_search(conversation), cal: cal, web: web }
  end

  # Biblioteca de TRs da Papyrus (ReferenceTerm): busca pelo mesmo descritor do serviço do acervo.
  def library_search(conversation)
    ReferenceTerm.similar_to(conversation.service_descriptor, limit: SEED_RESULTS_PER_QUERY).map do |term|
      studies = StudyType.where(code: term.study_types).pluck(:name).join(", ")
      [ term.id, "#{term.label}#{" (#{term.municipality})" if term.municipality.present?} — estudos: #{studies.presence || 'não indicado'}; " \
                 "atividade: #{term.activities.presence || 'genérico'}. #{term.summary.to_s.truncate(240)}" ]
    end
  rescue StandardError => e
    Rails.logger.warn("FindTermOfReferenceJob: busca na biblioteca falhou: #{e.class} #{e.message}")
    []
  end

  def cal_search(query)
    return [] unless Cal::Client.configured?

    Cal::Normas.new.search(palavra_chave: query).normas.first(SEED_RESULTS_PER_QUERY)
      .map { |norma| [ norma.codigo, "#{norma.tipo_e_numero} (#{norma.orgao}, #{norma.ambito}) — #{norma.assunto.to_s.truncate(240)}" ] }
  rescue StandardError => e
    Rails.logger.warn("FindTermOfReferenceJob: busca no CAL falhou (#{query}): #{e.class} #{e.message}")
    []
  end

  def web_search(query)
    return [] unless WebSearch::Client.configured?

    WebSearch::Client.new.search(query, max_results: SEED_RESULTS_PER_QUERY)
      .map { |result| [ result.url, "#{result.title} — #{result.content.to_s.squish.truncate(240)}" ] }
  rescue StandardError => e
    Rails.logger.warn("FindTermOfReferenceJob: busca na internet falhou (#{query}): #{e.class} #{e.message}")
    []
  end

  def seeds_text(seeds)
    lines = ->(list, key) { list.to_a.map { |id, text| "- #{key}#{id}: #{text}" }.join("\n").presence || "(nada)" }
    <<~TEXT
      Resultados que o sistema já buscou (ponto de partida — leia o texto completo das normas
      promissoras com search_legal_norms/codigo_norma e busque mais se nenhum servir):
      Biblioteca de TRs da Papyrus (TRs oficiais que a Papyrus já juntou — PREFIRA quando servir):
      #{lines.call(seeds[:library], "id ")}
      CAL:
      #{lines.call(seeds[:cal], "")}
      Internet:
      #{lines.call(seeds[:web], "")}
    TEXT
  end

  def searchable? = ReferenceTerm.searchable.exists? || Cal::Client.configured? || WebSearch::Client.configured?

  # O automático fica quieto quando não acha (não é pendência de ninguém); o pedido no chat responde.
  def tell(conversation, text, force)
    return unless force

    conversation.post_system_notice!(text)
  end

  def context_for(conversation)
    findings = conversation.project_findings.active
    studies = conversation.study_types.map(&:name)
    licenses = findings.where(field: "tipo_licenca").pluck(:value).uniq
    return nil if studies.empty? && licenses.empty?

    [
      ("Estudo(s): #{studies.join(', ')}" if studies.any?),
      ("Licença(s): #{licenses.join(', ')}" if licenses.any?),
      ("Empreendimento: #{findings.where(field: 'empreendimento').pluck(:value).first}" if findings.where(field: "empreendimento").exists?),
      ("Município(s): #{findings.where(field: 'municipios').pluck(:value).flat_map { |v| v.split(',') }.map(&:squish).uniq.first(8).join(', ')}" if findings.where(field: "municipios").exists?),
      ("Órgão ambiental: #{findings.where(field: 'orgao_ambiental').pluck(:value).first}" if findings.where(field: "orgao_ambiental").exists?),
      ("Enquadramento legal: #{findings.where(field: 'enquadramento_legal').pluck(:value).first}" if findings.where(field: "enquadramento_legal").exists?)
    ].compact.join("\n")
  end

  def prompt(conversation, context, seeds)
    rejected = conversation.term_of_reference_candidates.where(status: "rejected").map { |c| "- #{c.title} (#{c.norm_code || c.url})" }

    <<~TEXT
      Procure o TERMO DE REFERÊNCIA (TR) oficial do órgão ambiental competente para o estudo desta
      proposta — o documento do órgão que diz o conteúdo mínimo e a metodologia do estudo. O cliente
      não enviou um; se você achar, ele vai como anexo da proposta (o consultor confirma antes).

      #{context}

      #{seeds_text(seeds)}
      Se nada acima servir com certeza, PESQUISE MAIS antes de desistir: outras buscas no CAL e na
      internet, variando os termos
      (ex.: "termo de referência" + sigla do estudo + atividade; "termo de referência" + órgão;
      "conteúdo mínimo" + estudo; o nome do órgão + "TR" + atividade).

      Onde procurar, nesta ordem:
      0. A BIBLIOTECA de TRs da Papyrus listada acima: TR oficial que a Papyrus já tem. Se um deles é
         do órgão competente e serve pra este estudo e atividade, proponha ele (fonte "biblioteca").
      1. CAL (search_legal_norms_archive, se existir, e search_legal_norms): muitos TRs saem como
         portaria/instrução normativa/resolução que "aprova o Termo de Referência" para o estudo e a
         atividade. Leia o TEXTO COMPLETO (search_legal_norms com codigo_norma) antes de concluir — a
         norma tem que CONTER o TR, não só citar que existe um.
      2. Internet (web_search), só se o CAL não tiver: o PDF ou Word do TR no site OFICIAL do órgão
         (gov.br, site da secretaria/instituto). Precisa ser o link direto do ARQUIVO; página que só
         fala do TR não serve.

      Só serve se for: do órgão competente pra ESTE caso (mesmo estado/esfera), pro MESMO tipo de
      estudo, pra atividade compatível com este empreendimento (ou genérico do estudo, quando o órgão
      só tem um), e vigente. Nunca de outro estado, de outra atividade, notícia, blog ou modelo de
      consultoria.
      #{"Já descartados pelo consultor (não proponha de novo):\n#{rejected.join("\n")}" if rejected.any?}

      Responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois):
      {"termo_referencia": null}
      ou
      {"termo_referencia": {"fonte": "biblioteca", "id_biblioteca": 12, "titulo": "...", "justificativa": "..."}}
      ou
      {"termo_referencia": {"fonte": "cal", "codigo_norma": "NL1234", "titulo": "Portaria nº ... — TR para EIA/RIMA de ...", "justificativa": "por que serve pra este caso, em uma frase"}}
      ou
      {"termo_referencia": {"fonte": "internet", "url": "https://.../tr.pdf", "titulo": "...", "justificativa": "..."}}
      Na dúvida, null — é melhor não propor nada do que propor o TR errado.
    TEXT
  end

  def library_candidate(conversation, found)
    term = ReferenceTerm.active.find_by(id: found["id_biblioteca"].to_i)
    return nil unless term
    return nil if conversation.term_of_reference_candidates.where(status: "rejected", reference_term: term).exists?

    conversation.term_of_reference_candidates.new(source: "biblioteca", reference_term: term, title: term.title,
      reason: found["justificativa"].to_s.strip.presence)
  end

  def parse(conversation)
    reply = conversation.messages.where(role: "assistant").order(:created_at).last
    found = AiJsonResponse.parse(reply&.content)
    found.is_a?(Hash) ? found["termo_referencia"].presence : nil
  end

  def build_candidate(conversation, found)
    return nil unless found.is_a?(Hash)

    source = found["fonte"].to_s
    return library_candidate(conversation, found) if source == "biblioteca"

    code = found["codigo_norma"].to_s.strip.presence
    url = found["url"].to_s.strip.presence
    return nil unless (source == "cal" && code) || (source == "internet" && url)
    return nil if conversation.term_of_reference_candidates.where(status: "rejected").where(source == "cal" ? { norm_code: code } : { url: url }).exists?

    conversation.term_of_reference_candidates.new(
      source: source, norm_code: (code if source == "cal"), url: (url if source == "internet"),
      title: found["titulo"].to_s.strip.presence || "Termo de Referência", reason: found["justificativa"].to_s.strip.presence
    )
  end
end
