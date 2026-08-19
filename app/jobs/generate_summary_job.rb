class GenerateSummaryJob < ApplicationJob
  queue_as :default

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)

    conversation.ask_internally(build_prompt(conversation))

    conversation.mark_step!("summary", "done")
    conversation.update!(status: "reviewing")
  rescue StandardError => e
    Rails.logger.error("GenerateSummaryJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    conversation&.mark_step!("summary", "failed")
  end

  private
    def build_prompt(conversation)
      <<~TEXT
        Monte um resumo estruturado para o consultor da Papyrus revisar, com base nos dados já
        extraídos abaixo. Escreva em português, organizado em tópicos claros. Se alguma informação
        não estiver disponível, diga isso explicitamente em vez de inventar.

        #{extracted_data_summary(conversation)}

        #{geospatial_summary(conversation)}
      TEXT
    end

    # Determinístico (KmzGeometryExtractor) — só informa o que já foi calculado, a IA não
    # recalcula nem estima área/perímetro por conta própria (CLAUDE.md seção 1).
    def geospatial_summary(conversation)
      result = conversation.geospatial_result
      return "" unless result

      "Dados geoespaciais do KMZ (já calculados pelo sistema): #{result.summary_text}"
    end

    def extracted_data_summary(conversation)
      parsed_findings = conversation.messages.where(role: "assistant").filter_map { |message| parse_json(message.content) }
      return "Nenhum dado estruturado disponível ainda." if parsed_findings.empty?

      parsed_findings.map { |hash| format_hash(hash) }.join("\n\n")
    end

    def parse_json(text)
      return nil if text.blank?

      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    def format_hash(hash)
      hash.map do |key, value|
        formatted_value = value.is_a?(Array) ? value.join("; ") : value
        "#{key}: #{formatted_value.presence || 'não informado'}"
      end.join("\n")
    end
end
