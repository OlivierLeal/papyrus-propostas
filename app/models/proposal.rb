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

  # Número da proposta = prefixo do tipo de arquivo + ano de criação (2 dígitos) + id da tabela,
  # preenchido com zero à esquerda até 3 dígitos (ver passo a passo interno, item 1 — exemplo real
  # deles: PTC21089) — automático, não é a IA que decide nem precisa de confirmação com a Charlene
  # antes de gerar o rascunho. Mesmo id em toda revisão/variante da mesma proposta — só o prefixo
  # muda entre técnica/comercial/combinado.
  def docx_numero_proposta(kind = "combined")
    "#{DOCX_NUMERO_PREFIXES.fetch(kind, "PTC")}#{created_at.strftime("%y")}#{id.to_s.rjust(3, "0")}"
  end

  # Nome de arquivo no padrão real da Papyrus (passo a passo interno, item 1 — exemplo deles:
  # PTC21089_Rural e CIA Eng e Geotec_IF_Prado_BA_Rev.00.docx): número + cliente + escopo (tipo de
  # estudo + município/UF, quando a IA já os identificou) + revisão atual. municipio/estado vêm de
  # fora (só existem como texto solto que a IA extraiu na hora de gerar — ver
  # GenerateProposalDocumentTool) porque hoje não são persistidos em nenhuma coluna própria.
  # "Rev.00", "Rev 1", "rev.02" — qualquer forma de revisão que o consultor tenha escrito à mão
  # no nome que ele ditou. Se ele escreveu uma, é a dele que vale.
  REVISION_MARKER = /rev\.?\s*\d+/i

  # Prefixo do número da proposta no começo do nome (PTC26002_...), que é o que distingue
  # técnica de comercial na convenção da Papyrus.
  NUMBER_PREFIX = /\A(PTC|PT|PC)\d/i

  def docx_filename(kind, municipio: nil, estado: nil)
    base = docx_filename_override.presence ? custom_filename_base(kind) : standard_filename_base(kind, municipio, estado)
    base += "_Rev.#{format("%02d", version - 1)}" unless base.match?(REVISION_MARKER)

    "#{base}.docx"
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

  # Preço total por extenso na frase de abertura da seção 10 — o modelo da Papyrus (revisão de
  # 2026-08) deixou de trazer o quadro de preço aberto por profissional/entregável, então o valor
  # que o cliente lê é este. Continua vindo do motor determinístico, nunca da IA.
  def docx_total_price
    "R$ #{format_currency(project_pricing.total_value)}"
  end

  # Linhas do Quadro 10-1 (Desembolso) — marco, valor em R$ e data de cada parcela, direto do
  # payment_schedule. A data é preenchida pelo consultor na Tela de Precificação; parcela sem
  # data sai em branco no documento, para ele fechar no Word.
  def docx_payment_schedule_rows
    project_pricing.payment_schedule_amounts.map do |item|
      [ item["label"], format_currency(item["amount"]), formatted_date(item["date"]) ]
    end
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
  # extraído do ET, do TR (quando houver) e dos documentos complementares desta conversa
  # (CLAUDE.md seção 5).
  # A sugestão é restrita ao "menu" de profissionais/entregáveis do study_templates —
  # a IA nunca pode inventar um profissional ou entregável que não exista no sistema.
  # Se a IA falhar ou não sugerir nada válido, cai no template padrão como segurança.
  def build_with_ai_suggested_team!
    templates = conversation.study_type.study_templates.includes(:professional).to_a
    pricing = create_project_pricing!

    if templates.empty?
      ensure_always_included_lines!(pricing, templates)
      return finalize!(pricing)
    end

    suggestion = fetch_ai_suggestion(templates)
    apply_lines!(pricing, Array(suggestion["linhas"]), templates)
    apply_lines!(pricing, template_fallback_lines(templates), templates) if pricing.proposal_professionals.none?
    ensure_always_included_lines!(pricing, templates)
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
    ensure_always_included_lines!(pricing, templates)
    finalize!(pricing)
  end

  private
    def standard_filename_base(kind, municipio, estado)
      cliente = sanitize_for_filename(conversation.client_name)
      escopo = [ conversation.study_type&.name, sanitize_for_filename(municipio), estado.presence&.upcase ]
        .compact_blank.join("_")

      "#{docx_numero_proposta(kind)}_#{cliente}#{"_#{escopo}" if escopo.present?}"
    end

    # O consultor ditou o nome; o sistema só cuida do que distingue os DOIS arquivos quando a
    # proposta sai separada em técnica e comercial — senão os dois sairiam com o mesmo nome.
    # Quando o nome dele já começa pelo número da proposta, trocar PTC/PT/PC é a própria
    # convenção da Papyrus; quando não começa, o sufixo é o jeito de não colidir.
    def custom_filename_base(kind)
      name = sanitize_for_filename(docx_filename_override).to_s.sub(/\.docx\z/i, "").strip
      return name if kind == "combined"
      return name.sub(/\A(PTC|PT|PC)/i, DOCX_NUMERO_PREFIXES.fetch(kind, "PTC")) if name.match?(NUMBER_PREFIX)

      "#{name}_#{kind == "tecnica" ? "Tecnica" : "Comercial"}"
    end

    def sanitize_for_filename(text)
      text.to_s.gsub(%r{[/\\:*?"<>|]}, "-").presence
    end

    def formatted_date(value)
      Date.parse(value.to_s).strftime("%d/%m/%Y")
    rescue Date::Error, TypeError
      ""
    end

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
        ambiental, com base em tudo que já foi analisado nesta conversa (ET, TR quando houver, e
        documentos complementares, incluindo propostas anteriores semelhantes, se houver).

        Profissionais e entregáveis DISPONÍVEIS para o tipo de estudo "#{conversation.study_type.name}"
        (não sugira nada fora desta lista — nunca invente professional_id ou entregável novo):
        #{menu}

        Para CADA item da lista acima, sugira as horas necessárias para este projeto específico,
        considerando a complexidade, os diagnósticos exigidos e as demais informações já extraídas
        nesta conversa. Se um item não for necessário para este projeto, sugira 0 para ambas as horas.

        Além disso, releia o ET e o TR (quando houver) e diga se algum deles exige que a proposta
        técnica e a proposta comercial sejam apresentadas como documentos/envelopes SEPARADOS
        (comum em licitação pública) — se nenhum falar nada sobre isso, considere que NÃO exige
        (documento único).

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
        # A regra determinística continua: linha fora do cadastro NÃO entra na precificação. O que
        # mudou é que ela para de sumir em silêncio — a IA ter sugerido um profissional ou
        # entregável que não existe é informação para o consultor (ou falta cadastro, ou a IA
        # inventou), não um detalhe de implementação.
        next flag_out_of_catalog(line) unless template

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

    # Profissionais fixos (professionals.always_included — Diretoria/Coordenação da Papyrus)
    # entram em TODA proposta, com as horas padrão do template como ponto de partida. apply_lines!
    # pula linha com 0h nos dois campos (ver acima) e a IA pode simplesmente não sugerir a linha
    # — nenhum dos dois casos pode fazer um fixo sumir da equipe, então a garantia é do sistema,
    # não da sugestão da IA. O consultor ainda ajusta as horas depois, na Tela de Precificação.
    #
    # NÃO itera só sobre `templates`: um study_type sem NENHUM study_template cadastrado (RAP,
    # Relatório Técnico, PEA, EMI, hoje — ver CLAUDE.md seção 11.1) tem `templates` vazio, e antes
    # disso fazia o fixo sumir também nesses casos — achado comparando uma proposta EMI gerada
    # pelo sistema com a PTC real aprovada pela Papyrus (nem Charlene/Ricardo apareciam). Por isso
    # a fonte da verdade aqui é `Professional.always_included`, com o "role" como deliverable_name
    # quando não há template pro study_type dessa proposta pra saber o nome do entregável.
    def ensure_always_included_lines!(pricing, templates)
      present = pricing.proposal_professionals.pluck(:professional_id, :deliverable_name).to_set
      templates_by_professional = templates.group_by(&:professional_id)

      Professional.active.always_included.find_each do |professional|
        professional_templates = templates_by_professional[professional.id]

        if professional_templates.present?
          professional_templates.each do |template|
            next if present.include?([ template.professional_id, template.deliverable_name ])

            pricing.proposal_professionals.create!(
              professional: template.professional,
              deliverable_name: template.deliverable_name,
              hours_office: template.hours_office_default,
              hours_field: template.hours_field_default
            )
          end
        else
          deliverable_name = professional.role
          next if present.include?([ professional.id, deliverable_name ])

          pricing.proposal_professionals.create!(
            professional: professional, deliverable_name: deliverable_name, hours_office: 0, hours_field: 0
          )
        end
      end
    end

    def flag_out_of_catalog(line)
      professional = Professional.find_by(id: line["professional_id"])
      descricao = [ professional&.name || "profissional ##{line['professional_id']}",
                    line["deliverable_name"].presence ].compact_blank.join(" — ")

      conversation.project_findings.create!(
        field: "outro", nature: "sugestao", source_kind: "sistema",
        value: "sugestão de equipe fora do cadastro: #{descricao}",
        excerpt: "A IA sugeriu esta linha para a equipe, mas ela não existe nos modelos de horas " \
                 "cadastrados para o tipo de estudo. Não entrou na precificação."
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[Proposal] não consegui registrar sugestão fora do cadastro: #{e.message}")
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
