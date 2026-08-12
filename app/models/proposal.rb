class Proposal < ApplicationRecord
  belongs_to :conversation
  has_one :project_pricing, dependent: :destroy

  STATUSES = %w[draft priced approved].freeze
  DOCUMENT_SPLITS = %w[combined separated].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :document_split, inclusion: { in: DOCUMENT_SPLITS }

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
    def finalize!(pricing)
      pricing.recalculate!
      pricing
    end

    def fetch_ai_suggestion(templates)
      conversation.ask_internally(suggestion_prompt(templates), hide_response: true)
      response = conversation.messages.where(role: "assistant").order(:created_at).last
      JSON.parse(strip_json_fences(response.content))
    rescue JSON::ParserError, TypeError
      {}
    end

    # O Gemini às vezes ignora a instrução "sem markdown" e envolve a resposta em
    # ```json ... ``` — removemos as cercas antes do parse em vez de depender do prompt.
    def strip_json_fences(text)
      text.to_s.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "")
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
