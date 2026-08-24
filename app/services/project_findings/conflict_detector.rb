module ProjectFindings
  # Descobre onde os documentos desta proposta discordam entre si (seção 13 do documento de
  # arquitetura). Roda no GenerateSummaryJob, único ponto que só acontece depois de TR, KMZ e
  # complementares terminarem.
  #
  # A ordem das etapas é o que segura o custo e a precisão:
  #
  #   1. Só campo comparável entra (ProjectFinding::FIELDS) — lista acumulativa não contradiz.
  #   2. Só grupo com origens DIFERENTES entra: dois trechos do mesmo TR dizendo coisas diferentes
  #      normalmente são recortes do mesmo assunto, não divergência entre fontes.
  #   3. Igualdade textual e comparação numérica resolvem sem IA nenhuma. "500 ha" × "620 ha" é
  #      divergência aritmética, e perguntar isso a um modelo seria pagar para ter uma resposta
  #      pior do que uma subtração.
  #   4. Só o que sobra vai à IA, numa ÚNICA chamada em lote, e só para julgar se a diferença é de
  #      grafia ou de conteúdo. O veredito é menu fechado, e qualquer resposta fora dele conta
  #      como equivalente — inventar divergência que não existe custa a confiança do consultor.
  class ConflictDetector
    # Diferença relativa a partir da qual dois números são considerados divergentes. Abaixo disso
    # é arredondamento de área/perímetro entre o que o documento declara e o que o KMZ mede.
    NUMERIC_TOLERANCE = 0.02

    def initialize(conversation)
      @conversation = conversation
    end

    # Devolve os conflitos criados. Nunca levanta: divergência não detectada atrasa a revisão,
    # mas resumo não gerado trava a proposta inteira.
    def call
      groups = candidate_groups
      return [] if groups.empty?

      numeric, textual = groups.partition { |group| group.first.numeric_field? }

      divergences = numeric.filter_map { |group| numeric_divergence(group) }
      divergences += ai_divergences(textual) if textual.any?

      divergences.map { |group, summary| create_conflict(group, summary) }
    rescue StandardError => e
      Rails.logger.error("[ConflictDetector] falhou para conversation #{@conversation.id}: #{e.class} #{e.message}")
      []
    end

    private

    def candidate_groups
      existing_fields = @conversation.project_conflicts.pluck(:field)

      @conversation.project_findings.active.comparable
        .where.not(field: existing_fields)
        .order(:id)
        .group_by(&:field)
        .values
        .select { |group| divergent_candidates?(group) }
    end

    # Precisa de valores diferentes E de origens diferentes para valer a pena olhar.
    def divergent_candidates?(group)
      group.map { |finding| normalize(finding.value) }.uniq.size > 1 &&
        group.map(&:source_kind).uniq.size > 1
    end

    def normalize(value)
      value.to_s.downcase.strip.gsub(/\s+/, " ")
    end

    def numeric_divergence(group)
      numbers = group.filter_map { |finding| parse_number(finding.value) }
      return nil if numbers.size < 2

      spread = (numbers.max - numbers.min) / numbers.max.abs
      return nil if spread < NUMERIC_TOLERANCE

      label = group.first.field_label
      [ group, "#{label} difere entre as fontes: #{format_numbers(numbers)} (#{(spread * 100).round(1)}% de diferença)." ]
    end

    def parse_number(value)
      # "620,4 ha" e "1.234,56" — vírgula decimal e ponto de milhar, como vem em documento em
      # português. Sem isso "1.234,56" viraria 1.23.
      cleaned = value.to_s.gsub(/[^\d,.\-]/, "").sub(/\.(?=\d{3}\b)/, "").tr(",", ".")
      Float(cleaned)
    rescue ArgumentError, TypeError
      nil
    end

    def format_numbers(numbers)
      numbers.map { |number| number.round(2).to_s }.join(" × ")
    end

    def ai_divergences(groups)
      @conversation.ask_internally(judgement_prompt(groups), hide_response: true)
      parsed = AiJsonResponse.parse(last_reply) || {}

      Array(parsed["julgamentos"]).filter_map do |judgement|
        next unless judgement.is_a?(Hash) && judgement["veredito"].to_s.strip.downcase == "divergente"

        group = groups[judgement["indice"].to_i]
        next unless group

        summary = judgement["descricao"].to_s.strip.presence || default_summary(group)
        [ group, summary ]
      end
    end

    def last_reply
      @conversation.messages.where(role: "assistant").order(:created_at).last&.content
    end

    def default_summary(group)
      "#{group.first.field_label}: as fontes não dizem a mesma coisa."
    end

    def judgement_prompt(groups)
      blocks = groups.each_with_index.map do |group, index|
        values = group.map { |finding| "  - \"#{finding.value}\" (fonte: #{finding.origin_label})" }.join("\n")
        "índice #{index} — campo \"#{group.first.field_label}\":\n#{values}"
      end.join("\n\n")

      <<~TEXT
        Abaixo estão informações sobre O MESMO projeto extraídas de documentos DIFERENTES. Para
        cada índice, diga se os valores listados são a mesma coisa escrita de formas diferentes ou
        se realmente se contradizem.

        #{blocks}

        Considere EQUIVALENTE quando for só grafia, abreviação, sigla, ordem, unidade equivalente
        ou nível de detalhe diferente sobre a mesma coisa (ex.: "LP" e "Licença Prévia";
        "Prado/BA" e "Prado"). Considere DIVERGENTE apenas quando um documento afirma algo que o
        outro contradiz, e alguém precisaria decidir qual vale.

        Na dúvida, responda "equivalente" — apontar divergência que não existe faz o consultor
        perder tempo conferindo documento à toa.

        Responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois):

        {
          "julgamentos": [
            { "indice": 0, "veredito": "divergente", "descricao": "uma frase dizendo no que discordam" }
          ]
        }

        Em "descricao" (só para os divergentes), escreva uma frase curta em português explicando a
        contradição, sem sugerir qual valor está certo.
      TEXT
    end

    def create_conflict(group, summary)
      conflict = @conversation.project_conflicts.create!(field: group.first.field, summary: summary)
      group.each { |finding| conflict.project_conflict_findings.create!(project_finding: finding) }
      conflict
    end
  end
end
