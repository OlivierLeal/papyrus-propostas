module ProjectFindings
  # Transforma o JSON que a IA devolve na extração (TR e documentos complementares) em linhas de
  # ProjectFinding, com a origem junto.
  #
  # Duas regras que existem porque a resposta da IA nunca é confiável em formato:
  # - campo fora do menu não é descartado nem aceito como está — vira "outro", com o rótulo
  #   original preservado no valor. Descartar perderia informação; aceitar deixaria a IA criar
  #   chaves que não agrupam nem comparam com nada.
  # - natureza fora do menu vira "inferencia", nunca "fato": na dúvida sobre a procedência de uma
  #   afirmação, tratá-la como deduzida é o erro barato; tratá-la como lida no documento é o caro.
  class Recorder
    def initialize(conversation, source_kind:, source_blob: nil)
      @conversation = conversation
      @source_kind = source_kind
      @source_blob = source_blob
    end

    # payload: hash já parseado (AiJsonResponse.parse) no formato { "achados" => [...] }.
    # Devolve os achados criados.
    def call(payload)
      Array(payload&.dig("achados")).filter_map { |item| record(item) }
    end

    private

    def record(item)
      return nil unless item.is_a?(Hash)

      value = item["valor"].to_s.strip
      return nil if value.blank?

      field = normalize_field(item["campo"])
      @conversation.project_findings.create!(
        field: field,
        value: field == "outro" ? label_for_other(item, value) : value,
        nature: normalize_nature(item["natureza"]),
        source_kind: @source_kind,
        source_blob: @source_blob,
        excerpt: item["trecho"].to_s.strip.presence&.truncate(ProjectFinding::EXCERPT_LIMIT),
        locator: item["local"].to_s.strip.presence&.truncate(120)
      )
    rescue ActiveRecord::RecordInvalid => e
      # Um achado malformado não pode derrubar a extração inteira do documento.
      Rails.logger.warn("[ProjectFindings::Recorder] achado ignorado: #{e.message}")
      nil
    end

    def normalize_field(raw)
      field = raw.to_s.strip.downcase
      ProjectFinding::FIELDS.key?(field) ? field : "outro"
    end

    def normalize_nature(raw)
      nature = raw.to_s.strip.downcase
      ProjectFinding::NATURES.key?(nature) ? nature : "inferencia"
    end

    # O rótulo que a IA usou continua legível no valor — sem isso, "prazo de vistoria: 30 dias"
    # viraria só "30 dias", sem dizer 30 dias de quê.
    def label_for_other(item, value)
      label = item["campo"].to_s.strip.tr("_", " ")
      label.present? ? "#{label}: #{value}" : value
    end
  end
end
