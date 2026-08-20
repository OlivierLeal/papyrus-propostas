class Proposal < ApplicationRecord
  belongs_to :conversation
  has_one :project_pricing, dependent: :destroy
  has_many_attached :generated_documents

  STATUSES = %w[draft priced approved].freeze
  DOCUMENT_SPLITS = %w[combined separated].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :document_split, inclusion: { in: DOCUMENT_SPLITS }

  # PTC = técnica e comercial num arquivo só; PT = só a técnica; PC = só a comercial (ver
  # GenerateProposalDocumentTool#execute — cada arquivo gerado usa o prefixo do que ele é).
  DOCX_NUMERO_PREFIXES = { "combined" => "PTC", "tecnica" => "PT", "comercial" => "PC" }.freeze

  # Número da proposta = prefixo do tipo de arquivo + ano de criação (2 dígitos) + id da tabela
  # (ver passo a passo interno, item 11) — automático, não é a IA que decide nem precisa de
  # confirmação com a Charlene antes de gerar o rascunho. Mesmo id em toda revisão/variante da
  # mesma proposta — só o prefixo muda entre técnica/comercial/combinado.
  def docx_numero_proposta(kind = "combined")
    "#{DOCX_NUMERO_PREFIXES.fetch(kind, "PTC")}#{created_at.strftime("%y")}#{id}"
  end

  # Nome de arquivo no padrão real já usado pela Papyrus (ex.:
  # PTC25108_Girassol_Pedras do Litoral_Rev00.docx) — número + cliente + revisão atual.
  def docx_filename(kind)
    cliente = conversation.client_name.to_s.gsub(%r{[/\\:*?"<>|]}, "-")
    "#{docx_numero_proposta(kind)}_#{cliente}_Rev#{format("%02d", version - 1)}.docx"
  end

  # Nome/qualificação da Equipe Técnica no DOCX vêm de dados reais do sistema (proposal_
  # professionals + professionals.registration), nunca da IA — ela não deve inventar nome ou
  # registro profissional de alguém. "Líder do projeto" = quem tem mais horas de escritório
  # (normalmente quem coordena); "Segurança do trabalho" = quem tiver esse termo no cargo, se
  # existir alguém assim na equipe desta proposta (em branco se não houver).
  def team_slot_for_docx(role_hint: nil)
    lines = project_pricing&.proposal_professionals&.includes(:professional).to_a || []
    return [ "", "" ] if lines.empty?

    line = if role_hint
      lines.find { |l| l.professional.role.to_s.downcase.include?(role_hint.downcase) }
    else
      lines.max_by(&:hours_office)
    end
    return [ "", "" ] unless line

    professional = line.professional
    [ professional.name, [ professional.role, professional.registration ].compact_blank.join(" — ") ]
  end

  # Linhas do Quadro 10-1 (Preço) — direto de proposal_professionals + external_costs +
  # logística, sem passar pela IA (CLAUDE.md seção 5: preço nunca é calculado ou descrito pela IA).
  def docx_price_rows
    pricing = project_pricing
    rows = pricing.proposal_professionals.includes(:professional).map do |pp|
      [ "#{pp.professional.name} — #{pp.deliverable_name}", format_currency(pp.subtotal) ]
    end
    rows += pricing.external_costs.map { |c| [ c["description"], format_currency(c["value"]) ] }
    rows << [ "Logística (deslocamento, hospedagem, alimentação)", format_currency(pricing.logistics_total) ] if pricing.logistics_total.positive?
    rows
  end

  # Linhas do Quadro 10-2 (Desembolso) — direto do payment_schedule já calculado.
  def docx_payment_schedule_rows
    project_pricing.payment_schedule_amounts.map { |item| [ item["label"], "#{item['percentage']}%" ] }
  end

  # Linhas da tabela "Sumário de Revisões" (página 2 do modelo) — cada geração vira uma linha
  # nova, nunca apaga histórico. As versões passadas vêm do metadata já gravado nos blobs de
  # generated_documents (version/description); a data de cada uma é a do próprio blob
  # (created_at), sem precisar de coluna própria. Chamado com `version` já incrementado pra
  # versão atual (ver GenerateProposalDocumentTool) — a linha dela entra por último.
  def docx_revision_rows(current_description:)
    # Blobs sem version no metadata são de antes desse controle existir — sem número de revisão
    # nem descrição pra mostrar, não entram na tabela (evita linha "-1" em branco no documento).
    past_rows = generated_documents.map(&:blob)
      .select { |blob| blob.metadata["version"].present? }
      .group_by { |blob| blob.metadata["version"] }
      .map do |v, blobs|
        blob = blobs.first
        [ format("%02d", v.to_i - 1), blob.metadata["description"], blob.created_at.strftime("%d/%m/%Y") ]
      end
      .sort_by { |row| row[0] }

    past_rows << [ format("%02d", version - 1), current_description, Date.current.strftime("%d/%m/%Y") ]
  end

  # Pede pra IA sugerir horas por profissional/entregável com base em tudo que já foi
  # extraído do TR e dos documentos complementares desta conversa (CLAUDE.md seção 5).
  # A sugestão é restrita ao "menu" de profissionais/entregáveis do study_templates —
  # a IA nunca pode inventar um profissional ou entregável que não exista no sistema.
  # Se a IA falhar ou não sugerir nada válido, cai no template padrão como segurança.
  def build_with_ai_suggested_team!
    templates = conversation.study_type.study_templates.includes(:professional).to_a
    pricing = create_project_pricing!
    return finalize!(pricing) if templates.empty?

    suggestion = fetch_ai_suggestion(templates)
    apply_lines!(pricing, Array(suggestion["linhas"]), templates)
    apply_lines!(pricing, template_fallback_lines(templates), templates) if pricing.proposal_professionals.none?
    update!(document_split: suggestion["documentos_separados"] ? "separated" : "combined")

    finalize!(pricing)
  rescue StandardError => e
    Rails.logger.error("build_with_ai_suggested_team! falhou para conversation #{conversation_id}: #{e.class} #{e.message}")
    project_pricing&.destroy
    build_from_template!
  end

  # Copia o template padrão direto, sem envolver a IA — usado como fallback de segurança.
  def build_from_template!
    templates = conversation.study_type.study_templates.includes(:professional).to_a
    pricing = create_project_pricing!
    apply_lines!(pricing, template_fallback_lines(templates), templates)
    finalize!(pricing)
  end

  private
    def format_currency(value)
      ActionController::Base.helpers.number_to_currency(value, unit: "", separator: ",", delimiter: ".").strip
    end

    def finalize!(pricing)
      pricing.recalculate!
      pricing
    end

    def fetch_ai_suggestion(templates)
      conversation.ask_internally(suggestion_prompt(templates), hide_response: true)
      response = conversation.messages.where(role: "assistant").order(:created_at).last
      AiJsonResponse.parse(response.content) || {}
    end

    def suggestion_prompt(templates)
      menu = templates.map do |t|
        "- professional_id: #{t.professional_id} | #{t.professional.name} (#{t.professional.role}) | " \
        "entregável: \"#{t.deliverable_name}\" | padrão: #{t.hours_office_default}h escritório, #{t.hours_field_default}h campo"
      end.join("\n")

      <<~TEXT
        Você é um assistente que sugere a composição de equipe para uma proposta de consultoria
        ambiental, com base em tudo que já foi analisado nesta conversa (TR e documentos
        complementares, incluindo propostas anteriores semelhantes, se houver).

        Profissionais e entregáveis DISPONÍVEIS para o tipo de estudo "#{conversation.study_type.name}"
        (não sugira nada fora desta lista — nunca invente professional_id ou entregável novo):
        #{menu}

        Para CADA item da lista acima, sugira as horas necessárias para este projeto específico,
        considerando a complexidade, os diagnósticos exigidos e as demais informações já extraídas
        nesta conversa. Se um item não for necessário para este projeto, sugira 0 para ambas as horas.

        Além disso, releia o TR e diga se ele exige que a proposta técnica e a proposta comercial
        sejam apresentadas como documentos/envelopes SEPARADOS (comum em licitação pública) — se o
        TR não falar nada sobre isso, considere que NÃO exige (documento único).

        Responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois), exatamente
        neste formato:

        {
          "linhas": [
            { "professional_id": 12, "deliverable_name": "Coordenação geral", "hours_office": 30, "hours_field": 0 }
          ],
          "documentos_separados": false,
          "justificativa_documentos_separados": "..."
        }
      TEXT
    end

    def apply_lines!(pricing, lines, templates)
      valid_templates = templates.index_by { |t| [ t.professional_id, t.deliverable_name.to_s.strip.downcase ] }

      lines.each do |line|
        key = [ line["professional_id"].to_i, line["deliverable_name"].to_s.strip.downcase ]
        template = valid_templates[key]
        next unless template

        hours_office = line["hours_office"].to_f
        hours_field = line["hours_field"].to_f
        next if hours_office.zero? && hours_field.zero?

        pricing.proposal_professionals.create!(
          professional: template.professional,
          deliverable_name: template.deliverable_name,
          hours_office: hours_office,
          hours_field: hours_field
        )
      end
    end

    def template_fallback_lines(templates)
      templates.map do |t|
        {
          "professional_id" => t.professional_id,
          "deliverable_name" => t.deliverable_name,
          "hours_office" => t.hours_office_default,
          "hours_field" => t.hours_field_default
        }
      end
    end
end
