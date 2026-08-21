module Rag
  # Descobre o PAPEL de cada documento de um job do acervo.
  #
  # Essa é a decisão mais importante do pipeline. Numa pasta de job convivem a proposta que a
  # Papyrus escreveu e a especificação técnica que o cliente mandou — e a do cliente costuma
  # ser MAIOR. Jogadas no mesmo índice sem distinção, perguntar "como a Papyrus descreve o
  # escopo" devolve texto escrito pela Petrobras, e o RAG passa a ensinar a IA a imitar o
  # cliente em vez da própria Papyrus.
  #
  # A estrutura de pastas ajuda mas não decide: no acervo real ela varia de job para job
  # ("Docs Papyrus" x "Doc´s Papyrus", "Doc´s Cliente" x "Doc´s Clientes") e não há garantia
  # de que um job novo siga qualquer convenção. Por isso o caminho é um SINAL entre outros, e
  # quem conclui é a IA — restrita a um menu fechado de papéis, do mesmo jeito que
  # Proposal#build_with_ai_suggested_team! restringe a sugestão de equipe ao que existe
  # cadastrado. Se a IA falhar ou devolver um papel que não existe, vale a heurística.
  class DocumentClassifier
    ROLES = {
      "proposta_papyrus" => "Proposta técnica e/ou comercial escrita pela Papyrus",
      "tr_cliente" => "Termo de Referência, especificação técnica ou escopo enviado pelo cliente",
      "tr_papyrus" => "Termo de Referência escrito PELA Papyrus para contratar terceiros/provedores",
      "anexo_tecnico" => "Anexo técnico do cliente: procedimento operacional, norma, diretriz",
      "modelo_documento" => "Modelo/formulário em branco a ser preenchido (laudo, relatório)",
      "documento_contratual" => "Minuta de contrato, declaração, critério de habilitação, condições gerais",
      "planilha_papyrus" => "Planilha interna da Papyrus: memória de cálculo, HH, custos",
      "planilha_cliente" => "Planilha de preços do cliente (PPU, DFP) a ser preenchida",
      "outro" => "Não se encaixa em nenhum dos anteriores"
    }.freeze

    # Só estes papéis ensinam a IA a ESCREVER como a Papyrus. Os demais entram no índice para
    # consulta (casar TR parecido, conferir exigência técnica), nunca como modelo de escrita.
    #
    # tr_papyrus fica DE FORA de propósito, mesmo sendo texto da própria Papyrus: é um TR de
    # subcontratação, com estrutura completamente diferente de uma proposta comercial. Deixá-lo
    # aqui ensinaria a IA a escrever o documento errado. Ele continua indexado e é excelente
    # fonte de escopo técnico ("que diagnósticos entram num EMI de solar") — só não é modelo
    # de redação de proposta.
    VOICE_OF_PAPYRUS = %w[proposta_papyrus planilha_papyrus].freeze

    # Trecho enviado à IA por documento. O suficiente para reconhecer do que se trata sem
    # transformar a classificação de um job inteiro num envio de acervo.
    SAMPLE_CHARS = 600

    Classification = Data.define(:role, :confidence, :source) do
      def voice_of_papyrus? = VOICE_OF_PAPYRUS.include?(role)
    end

    def initialize(job, samples: {}, use_ai: true)
      @job = job
      @samples = samples
      @use_ai = use_ai
    end

    # Devolve { caminho_relativo => Classification }.
    def call
      heuristics = @job.items.index_by(&:relative_path).transform_values { |item| heuristic_for(item) }
      return heuristics if @job.items.empty? || !@use_ai

      merge_ai(heuristics)
    end

    private

    def merge_ai(heuristics)
      answers = ask_ai
      return heuristics if answers.blank?

      heuristics.each_with_object({}) do |(path, fallback), result|
        role = answers[path]
        result[path] = if ROLES.key?(role)
          Classification.new(role: role, confidence: :high, source: :ai)
        else
          fallback
        end
      end
    end

    def ask_ai
      response = RubyLLM.chat.ask(prompt).content
      parsed = AiJsonResponse.parse(response)
      return nil unless parsed.is_a?(Hash)

      parsed
    rescue StandardError => e
      # Classificar é melhor-esforço: sem IA o pipeline segue com a heurística de caminho,
      # em vez de abortar a ingestão de um acervo inteiro por uma falha de rede.
      Rails.logger.warn("[Rag::DocumentClassifier] job #{@job.name}: #{e.class} #{e.message}")
      nil
    end

    def prompt
      <<~TEXT
        Você está organizando o acervo de propostas da Papyrus Consultoria Ambiental para
        alimentar uma busca por similaridade. Cada pasta é um job (uma oportunidade comercial)
        e contém documentos de origens diferentes: uns foram escritos PELA Papyrus, outros
        foram recebidos DO cliente.

        Job: #{@job.name}
        Cliente identificado pela pasta: #{@job.client_name || "não identificado"}

        Atenção a uma distinção que confunde: um "Termo de Referência" pode ter sido RECEBIDO
        do cliente (tr_cliente) ou ESCRITO pela Papyrus para contratar prestadores (tr_papyrus).
        Documento com cabeçalho tipo "Preenchimento Papyrus" ou que define o que um provedor
        deve entregar à Papyrus é tr_papyrus, não proposta.

        Classifique cada arquivo abaixo em exatamente um destes papéis:
        #{ROLES.map { |role, description| "- #{role}: #{description}" }.join("\n")}

        Preste atenção ao caminho e ao trecho de conteúdo, não só ao nome do arquivo. O nome da
        pasta é uma pista, mas é inconsistente entre jobs — quem decide é o conteúdo.

        ARQUIVOS:
        #{files_section}

        Responda APENAS com um objeto JSON mapeando o caminho exato de cada arquivo para o
        papel escolhido, sem markdown e sem explicação. Exemplo:
        {"25001_Cliente/proposta.docx": "proposta_papyrus"}
      TEXT
    end

    def files_section
      @job.items.map do |item|
        sample = @samples[item.relative_path].to_s.squish.truncate(SAMPLE_CHARS)

        <<~ITEM
          - caminho: #{item.relative_path}
            trecho: #{sample.presence || "(sem texto extraído)"}
        ITEM
      end.join("\n")
    end

    # Sinais baratos, usados como resposta de reserva quando a IA não está disponível. São
    # deliberadamente conservadores: na dúvida, "outro" é melhor que classificar errado e
    # contaminar a voz da Papyrus com texto do cliente.
    def heuristic_for(item)
      path = item.relative_path.downcase

      role = if path.match?(/desatualizad/)
        "outro"
      elsif path.match?(/termo de refer/i)
        path.match?(/papyrus/) ? "tr_papyrus" : "tr_cliente"
      elsif path.match?(/papyrus/) && item.extension.match?(/xlsx?|xlsm/)
        "planilha_papyrus"
      elsif proposta?(item, path)
        "proposta_papyrus"
      elsif path.match?(/cliente/)
        "tr_cliente"
      else
        "outro"
      end

      Classification.new(role: role, confidence: :low, source: :heuristic)
    end

    def proposta?(item, path)
      return true if path.match?(/\bproposta\b/)

      # Documento cujo nome carrega o número do próprio job costuma ser a proposta dele.
      @job.numero.present? && item.numero_proposta == @job.numero && !path.match?(/cliente/)
    end
  end
end
