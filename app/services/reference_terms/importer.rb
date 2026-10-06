module ReferenceTerms
  # Importa uma pasta de TRs pra biblioteca (ReferenceTerm). Abre .zip, lê PDF/DOC/DOCX (OCR no
  # escaneado), pede à IA o que é cada arquivo (1 chamada por arquivo) e gera o embedding do
  # descritor. Arquivo que não é TR/roteiro (modelo de declaração, requerimento, mapa, lista de
  # espécies) fica como "ignored" — não volta a gastar IA na próxima importação.
  # Idempotente por SHA256 do arquivo.
  class Importer
    EXTENSIONS = %w[.pdf .doc .docx .odt .rtf].freeze
    MAX_TEXT = 60_000

    Result = Data.define(:imported, :ignored, :skipped, :failed)

    def initialize(path, embedder: Rag::Embedder.new, log: $stdout)
      @root = Pathname.new(path)
      @embedder = embedder
      @log = log
    end

    def call
      counts = { imported: 0, ignored: 0, skipped: 0, failed: 0 }
      each_file do |file, relative|
        status = import(file, relative)
        counts[status] += 1
        @log.puts("#{status.to_s.ljust(8)} #{relative}")
      end
      Result.new(**counts)
    end

    private

    def each_file(&block)
      Dir.mktmpdir("trs") do |tmp|
        Dir.glob(@root.join("**/*")).sort.each do |path|
          next unless File.file?(path)

          relative = Pathname.new(path).relative_path_from(@root).to_s
          if File.extname(path).casecmp?(".zip")
            expand_zip(path, File.join(tmp, File.basename(path, ".*")), relative, &block)
          elsif EXTENSIONS.include?(File.extname(path).downcase)
            yield Pathname.new(path), relative
          end
        end
      end
    end

    def expand_zip(zip_path, dir, relative_zip)
      Zip::File.open(zip_path) do |zip|
        zip.each do |entry|
          name = fix_encoding(entry.name)
          next unless entry.file? && EXTENSIONS.include?(File.extname(name).downcase)

          target = File.join(dir, name)
          FileUtils.mkdir_p(File.dirname(target))
          File.binwrite(target, entry.get_input_stream.read)
          yield Pathname.new(target), "#{relative_zip}/#{name}"
        end
      end
    end

    # Nome dentro de .zip do Windows vem em CP850 ("Refer\x88ncias" = "Referências") quando não é UTF-8.
    def fix_encoding(name)
      utf8 = name.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : name.dup.force_encoding(Encoding::CP850).encode(Encoding::UTF_8)
    rescue EncodingError
      name.dup.force_encoding(Encoding::UTF_8).scrub("_")
    end

    def import(file, relative)
      bytes = File.binread(file)
      sha = Digest::SHA256.hexdigest(bytes)
      return :skipped if ReferenceTerm.exists?(sha256: sha)

      text = extract_text(file)
      data = classify(text, relative)
      term = ReferenceTerm.new(sha256: sha, filename: File.basename(file), source_path: relative,
        content_type: Marcel::MimeType.for(Pathname.new(file), name: File.basename(file)), file_data: bytes,
        full_text: text.to_s[0, MAX_TEXT])
      apply(term, data)
      if term.status == "active"
        term.descriptor = descriptor(term)
        term.embedding = @embedder.embed_documents([ term.descriptor ]).first
        term.embedding_model = Rag::Embedder::MODEL_ID
      end
      term.save!
      term.status == "active" ? :imported : :ignored
    rescue StandardError => e
      @log.puts("  erro: #{e.class} #{e.message}")
      :failed
    end

    def extract_text(file)
      result = Rag::TextExtractor.new(file, ocr: true).call
      result.ok? ? result.plain_text : ""
    rescue StandardError
      ""
    end

    def classify(text, relative)
      return { "e_tr" => false, "motivo" => "sem texto legível" } if text.blank?

      AiJsonResponse.parse(RubyLLM.chat.ask(prompt(text, relative)).content) || {}
    end

    def apply(term, data)
      term.status = data["e_tr"] == true ? "active" : "ignored"
      term.title = data["titulo"].to_s.strip.presence || File.basename(term.filename, ".*")
      term.document_type = data["tipo"].to_s.presence
      term.number = data["numero"].to_s.presence
      term.organ = data["orgao"].to_s.presence
      term.uf = data["uf"].to_s.upcase.presence&.first(2)
      term.municipality = data["municipio"].to_s.presence
      term.study_types = Array(data["estudos"]).map(&:to_s).select { |code| StudyType.exists?(code: code) }
      term.activities = Array(data["atividades"]).join(", ").presence
      term.summary = data["resumo"].to_s.presence
      term.notes = data["motivo"].to_s.presence
    end

    # Mesmo formato de Conversation#service_descriptor: é com ele que a busca compara.
    def descriptor(term)
      studies = StudyType.where(code: term.study_types).pluck(:name)
      [ ("tipo estudo: #{studies.join('; ')}" if studies.any?), ("empreendimento: #{term.activities}" if term.activities),
        "documento: #{term.title}", ("órgão: #{term.organ} #{term.uf}" if term.organ), ("resumo: #{term.summary}" if term.summary) ].compact.join("\n")
    end

    def prompt(text, relative)
      <<~TEXT
        Classifique este documento da biblioteca de Termos de Referência da Papyrus (consultoria
        ambiental). Caminho do arquivo (dá pista do órgão): "#{relative}".

        "e_tr": true só se o documento diz O CONTEÚDO de um estudo/relatório/plano ambiental (Termo de
        Referência, roteiro de conteúdo mínimo, modelo de RCE/relatório com os itens exigidos, instrução
        normativa que define o conteúdo de um estudo). false pra modelo de declaração, requerimento,
        termo de responsabilidade, mapa, lista de espécies, planilha, formulário sem conteúdo de estudo.

        "tipo": um de #{TermOfReferenceAnnex::ANNEXABLE_TYPES.map { |t| "\"#{t}\"" }.join(', ')}.
        "estudos": códigos dos tipos de estudo cadastrados a que o documento se aplica (pode ser vazio):
        #{StudyType.ai_menu}
        "atividades": tipos de empreendimento/atividade (ex.: "usina solar", "parque eólico", "linha de
        transmissão", "indústria", "posto de combustível", "loteamento"), vazio se for genérico.

        Responda APENAS com JSON:
        {"e_tr": true, "titulo": "Termo de Referência — EMI de empreendimento solar", "tipo": "Termo de Referência",
         "numero": null, "orgao": "INEMA", "uf": "BA", "municipio": null, "estudos": ["emi"],
         "atividades": ["usina solar fotovoltaica"], "resumo": "o que o documento exige, em 2 frases", "motivo": "por que é ou não é TR"}

        Documento:
        #{text.to_s[0, 25_000]}
      TEXT
    end
  end
end
