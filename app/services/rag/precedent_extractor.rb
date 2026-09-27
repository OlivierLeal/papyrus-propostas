module Rag
  # Monta a ficha estruturada (JobPrecedent) de UM job do acervo: 1 chamada de IA sobre os trechos
  # que importam da proposta que a Papyrus escreveu (objetivo/escopo no início, e as seções de
  # equipe, preço e prazo), mais o texto classificado como planilha da Papyrus.
  #
  # A IA TRANSCREVE, não calcula (CLAUDE.md seção 1): valor total só se estiver escrito; horas e
  # diárias só se o quadro trouxer; campo ausente vira null. É a mesma regra de "fato do documento"
  # dos achados (ProjectFinding) aplicada ao acervo.
  class PrecedentExtractor
    VOICE = DocumentClassifier::VOICE_OF_PAPYRUS
    MAX_CHARS = 45_000
    # Planilha de precificação do job ("25010_Planilha_HH e Valores rev01.xlsx", vinculada pelo
    # inventário em HistoricalProposal#spreadsheet_path). É onde o VALOR mora: nas propostas
    # arquivadas o quadro de preço costuma estar em branco ("[inserir quadro]"). Só dá pra ler
    # onde o acervo está montado (máquina de indexação) — no servidor, o arquivo não existe e a
    # ficha sai só do texto da proposta.
    MAX_SPREADSHEET_CHARS = 25_000
    OPENING_CHUNKS = 6
    RELEVANT = /equipe|pre[çc]o|valor|honor[áa]rio|investimento|prazo|cronograma|desembolso|quadro|R\$\s*\d|horas?\b|di[áa]rias?/i

    def initialize(job_number, embedder: nil)
      @job_number = job_number
      @embedder = embedder || Embedder.new
    end

    def call
      proposals = HistoricalProposal.current.where(job_number: @job_number, role: VOICE).includes(:chunks).to_a
      precedent = JobPrecedent.find_or_initialize_by(job_number: @job_number)
      precedent.assign_attributes(
        client_name: proposals.map(&:client_name).compact.first,
        year: proposals.map(&:year).compact.max,
        source_documents: proposals.map(&:filename).uniq,
        extracted_at: Time.current, error_message: nil
      )

      text = source_text(proposals)
      sheet = spreadsheet_text(proposals)
      precedent.from_spreadsheet = sheet.present?
      text = [ sheet, text ].compact_blank.join("\n\n")
      return save_status(precedent, "no_data", "Job sem proposta/planilha da Papyrus indexada") if text.blank?

      data = AiJsonResponse.parse(RubyLLM.chat.ask(prompt(text)).content)
      return save_status(precedent, "failed", "Resposta da IA não era JSON") unless data.is_a?(Hash)

      apply(precedent, data)
      precedent.descriptor = descriptor(precedent)
      precedent.embedding = @embedder.embed_documents([ precedent.descriptor ]).first
      precedent.embedding_model = Embedder::MODEL_ID
      precedent.extraction_model = RubyLLM.config.default_model
      precedent.status = "ok"
      precedent.save!
      precedent
    rescue StandardError => e
      Rails.logger.error("[Rag::PrecedentExtractor] #{@job_number}: #{e.class} #{e.message}")
      save_status(precedent, "failed", "#{e.class}: #{e.message}".truncate(250)) if precedent
    end

    # Mesmo formato de Conversation#service_descriptor ("campo: valor" por linha) — é contra ele
    # que o descritor da proposta atual é comparado.
    def descriptor(precedent)
      {
        "tipo licenca" => precedent.license_acts.join("; "),
        "tipo estudo" => precedent.study_types.join("; "),
        "municipios" => precedent.location,
        "empreendimento" => precedent.enterprise,
        "diagnosticos" => precedent.service
      }.filter_map { |label, value| "#{label}: #{value.to_s.truncate(400)}" if value.present? }.join("\n")
    end

    private

    # Início da proposta (preâmbulo, objetivo, escopo) + seções de equipe/preço/prazo, em ordem,
    # até o teto. Mais recente primeiro: a última revisão é a que valeu.
    def source_text(proposals)
      budget = MAX_CHARS
      parts = proposals.sort_by { |proposal| [ -proposal.revision.to_i, proposal.filename ] }.flat_map do |proposal|
        chunks = proposal.chunks.sort_by(&:position)
        selected = chunks.first(OPENING_CHUNKS) + chunks.drop(OPENING_CHUNKS).select { |chunk| RELEVANT.match?("#{chunk.section_title} #{chunk.content}") }
        [ "### DOCUMENTO: #{proposal.filename} (#{proposal.role})" ] + selected.map(&:content)
      end

      parts.take_while { |part| (budget -= part.length).positive? }.join("\n\n")
    end

    def spreadsheet_text(proposals)
      path = proposals.map(&:spreadsheet_path).compact_blank.uniq.find { |candidate| File.exist?(candidate) }
      return nil unless path

      text = PricingSheetReader.new(path).call.to_text.truncate(MAX_SPREADSHEET_CHARS)
      text.present? ? "### PLANILHA DE PRECIFICAÇÃO DO JOB: #{File.basename(path)}\n#{text}" : nil
    end

    def apply(precedent, data)
      precedent.service = data["servico"].to_s.strip.presence
      precedent.study_types = Array(data["tipos_estudo"]).map(&:to_s).compact_blank
      precedent.license_acts = Array(data["atos_licenciamento"]).map(&:to_s).compact_blank
      precedent.enterprise = data["empreendimento"].to_s.strip.presence
      precedent.location = data["local"].to_s.strip.presence
      precedent.total_value = number(data["valor_total"])
      precedent.value_notes = data["valor_observacao"].to_s.strip.presence&.truncate(250)
      precedent.duration = data["prazo"].to_s.strip.presence&.truncate(250)
      precedent.team = Array(data["equipe"]).filter_map do |member|
        next unless member.is_a?(Hash) && member["funcao"].present?

        { "funcao" => member["funcao"].to_s.strip, "profissional" => member["profissional"].presence,
          "formacao" => member["formacao"].presence, "horas_homem" => number(member["horas_homem"]),
          "diarias" => number(member["diarias"]) }.compact
      end
      precedent.pricing_details = {
        "bdi" => number(data["bdi"]), "impostos" => number(data["impostos"]),
        "logistica" => Array(data["logistica"]).select { |item| item.is_a?(Hash) }.map { |item| { "descricao" => item["descricao"].to_s, "valor" => number(item["valor"]) }.compact },
        "observacoes" => data["observacoes_precificacao"].presence
      }.compact_blank
      precedent.other_costs = Array(data["outros_custos"]).filter_map do |cost|
        next unless cost.is_a?(Hash) && cost["descricao"].present?

        { "descricao" => cost["descricao"].to_s.strip, "valor" => number(cost["valor"]) }.compact
      end
    end

    # "R$ 1.234,56" / "1234.56" / 1234 → BigDecimal; qualquer outra coisa → nil.
    def number(value)
      return nil if value.blank?
      return value.to_d if value.is_a?(Numeric)

      text = value.to_s.gsub(/[^\d,.-]/, "")
      text = text.delete(".").tr(",", ".") if text.include?(",")
      text.present? ? BigDecimal(text) : nil
    rescue ArgumentError
      nil
    end

    def save_status(precedent, status, message)
      precedent.status = status
      precedent.error_message = message
      precedent.save!
      precedent
    end

    def prompt(text)
      <<~TEXT
        Abaixo estão trechos de uma proposta técnica/comercial que a Papyrus Consultoria Ambiental
        escreveu no passado (job #{@job_number}). Monte uma ficha estruturada do job TRANSCREVENDO o
        que está escrito. Regras:
        - Nunca calcule, some ou estime nada. Valor total só se estiver escrito como total do
          serviço; horas e diárias só se o quadro trouxer o número. Ausente = null.
        - "valor_total" em reais, número puro (ex.: 185000.00). Se houver vários serviços/opções
          com preços separados e nenhum total, deixe null e explique em "valor_observacao".
        - "equipe": uma linha por função/profissional do quadro de equipe ou de preço por hora
          (ex.: "Coordenador de Projetos", "Biólogo — fauna"). "horas_homem" = horas técnicas;
          "diarias" = dias de campo, só se o documento separar.
        - "tipos_estudo": siglas/nomes dos estudos (ex.: "EIA-RIMA", "RAP", "PCA", "Inventário
          Florestal"). "atos_licenciamento": LP, LI, LO, RLO, ASV, AMF, LU, Outorga…
        - "servico": uma frase objetiva do que foi contratado (sem nome de cliente).
        - Se houver "PLANILHA DE PRECIFICAÇÃO", ela é a fonte de valor, horas, diárias, BDI,
          impostos e logística (a proposta costuma ter o quadro de preço em branco). Transcreva
          o total que a planilha mostrar; "bdi"/"impostos" como fator (ex.: 1.20) ou percentual
          escrito; "logistica" = hospedagem, alimentação, veículo, combustível, passagens.

        Responda APENAS com JSON válido, neste formato:
        {
          "servico": "...", "tipos_estudo": [], "atos_licenciamento": [], "empreendimento": "...",
          "local": "município/UF", "valor_total": null, "valor_observacao": null, "prazo": "...",
          "equipe": [ { "funcao": "...", "profissional": null, "formacao": null, "horas_homem": null, "diarias": null } ],
          "outros_custos": [ { "descricao": "ART", "valor": null } ],
          "bdi": null, "impostos": null,
          "logistica": [ { "descricao": "Hospedagem", "valor": null } ],
          "observacoes_precificacao": null
        }

        TRECHOS:
        #{text}
      TEXT
    end
  end
end
