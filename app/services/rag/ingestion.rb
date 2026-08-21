module Rag
  # Orquestra as etapas 1 a 4 do pipeline de RAG do acervo histórico (CLAUDE.md seção 11.1):
  # inventário por job → extração de texto → classificação de papel → chunking → sensibilidade.
  #
  # Esta classe deliberadamente NÃO persiste nada: ela transforma uma pasta de arquivos numa
  # estrutura revisável. Assim dá para rodar o acervo inteiro, olhar o resultado e corrigir a
  # regra de corte antes de gastar o primeiro token de embedding.
  class Ingestion
    Chunk = Data.define(
      :position, :section_number, :section_title, :content,
      :char_count, :estimated_tokens, :sensitive, :contains_pricing, :sensitivity_reasons
    )

    Document = Data.define(
      :item, :status, :role, :role_source, :page_count, :chars_per_page,
      :chunks, :pricing_sheet_rows, :error
    ) do
      def ok? = status == :ok
      def indexable? = ok? && chunks.any? && !item.superseded
      def total_tokens = chunks.sum(&:estimated_tokens)
    end

    Job = Data.define(:name, :numero, :client_name, :subject, :documents) do
      def chunks = documents.flat_map(&:chunks)
      def indexable = documents.select(&:indexable?)
    end

    def initialize(path:, limit: nil, classify: true, ocr: false)
      @path = path
      @limit = limit
      @classify = classify
      @ocr = ocr
    end

    def call
      jobs = Inventory.new(@path).call
      jobs = jobs.first(@limit) if @limit

      jobs.map { |job| process_job(job) }
    end

    private

    def process_job(job)
      # A extração vem antes da classificação de propósito: o classificador decide melhor
      # vendo um trecho do conteúdo do que só o nome do arquivo.
      extractions = job.items.index_by(&:relative_path).transform_values { |item| extract(item) }
      roles = classify(job, extractions)

      documents = job.items.map do |item|
        build_document(item, extractions[item.relative_path], roles[item.relative_path])
      end
      documents = deduplicate(documents)

      Job.new(name: job.name, numero: job.numero, client_name: job.client_name,
              subject: job.subject, documents: documents)
    end

    # Variações do mesmo documento (o TR de "EMI - Solar" e o de "EMI - Junção") repetem blocos
    # inteiros de texto. Sem deduplicar, uma busca devolve o mesmo parágrafo cinco vezes e gasta
    # o contexto do Prompt 2 com redundância. O primeiro documento a apresentar o trecho fica
    # com ele; os demais perdem a cópia, não o arquivo.
    #
    # É por job de propósito: o mesmo texto institucional aparecendo na proposta da Petrobras
    # E na da Renova é informação legítima (mostra o padrão da Papyrus em contextos diferentes),
    # mas repetido cinco vezes dentro do mesmo job é só ruído.
    def deduplicate(documents)
      seen = Set.new

      documents.map do |document|
        kept = document.chunks.reject { |chunk| !seen.add?(chunk.content) }
        next document if kept.size == document.chunks.size

        document.with(chunks: kept.each_with_index.map { |chunk, index| chunk.with(position: index) })
      end
    end

    def classify(job, extractions)
      samples = extractions.transform_values { |extraction| extraction[:text] }
      DocumentClassifier.new(job, samples: samples, use_ai: @classify).call
    end

    def extract(item)
      result = TextExtractor.new(item.path, ocr: @ocr).call
      { result: result, text: result.text, error: nil }
    rescue TextExtractor::ExtractionError => e
      # Arquivo corrompido é regra, não exceção, num acervo de anos: registra e segue o lote.
      Rails.logger.warn("[Rag::Ingestion] #{item.filename}: #{e.message}")
      { result: nil, text: "", error: e.message }
    end

    def build_document(item, extraction, classification)
      result = extraction[:result]

      # Sem texto aproveitável não há o que chunkar: o documento entra no relatório com o
      # status que explica o porquê (needs_ocr, unsupported, empty) em vez de virar chunk vazio.
      chunks = result&.ok? ? build_chunks(result.text) : []

      Document.new(
        item: item,
        status: result&.status || :failed,
        role: classification.role,
        role_source: classification.source,
        page_count: result&.page_count || 0,
        chars_per_page: result&.chars_per_page || 0,
        chunks: chunks,
        pricing_sheet_rows: read_pricing_sheet(item),
        error: extraction[:error]
      )
    end

    def build_chunks(text)
      SectionChunker.new(text).call.map do |chunk|
        tags = SensitivityTagger.new(chunk.content).call

        Chunk.new(
          position: chunk.position,
          section_number: chunk.section_number,
          section_title: chunk.section_title,
          content: chunk.content,
          char_count: chunk.char_count,
          estimated_tokens: chunk.estimated_tokens,
          sensitive: tags.sensitive,
          contains_pricing: tags.contains_pricing,
          sensitivity_reasons: tags.reasons
        )
      end
    end

    def read_pricing_sheet(item)
      return 0 if item.spreadsheet_path.blank?

      PricingSheetReader.new(item.spreadsheet_path).call.row_count
    end
  end
end
