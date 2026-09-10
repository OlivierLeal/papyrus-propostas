require "test_helper"

module Rag
  # Ingestion orquestra inventário → extração → classificação → chunking → sensibilidade, SEM
  # tocar no banco. Os testes montam um acervo de verdade em disco (docx mínimo com estrutura de
  # seção) e rodam com `classify: false` pra usar só a heurística de caminho, sem chamar a IA.
  class IngestionTest < ActiveSupport::TestCase
    SECTION_XML = <<~XML.freeze
      <w:document xmlns:w="x"><w:body>
        <w:p><w:pPr><w:pStyle w:val="Ttulo1"/></w:pPr><w:r><w:t>OBJETIVO DOS SERVIÇOS</w:t></w:r></w:p>
        <w:p><w:r><w:t>%<body>s</w:t></w:r></w:p>
      </w:body></w:document>
    XML

    test "transforma uma pasta de job num Job com documento, papel e chunks — sem tocar no banco" do
      with_acervo("25001_Petrobras_Cetaceos" => { "Proposta Tecnica.docx" => docx("Elaboração de estudo ambiental para licenciamento. " * 12) }) do |path|
        assert_no_difference [ "HistoricalProposal.count", "HistoricalProposalChunk.count" ] do
          jobs = Ingestion.new(path: path, classify: false).call

          job = jobs.sole
          assert_equal "25001", job.numero
          assert_equal "Petrobras", job.client_name

          document = job.documents.sole
          assert document.ok?
          assert_equal "proposta_papyrus", document.role
          assert_equal :heuristic, document.role_source
          assert document.chunks.any?
          assert document.indexable?
        end
      end
    end

    test "deduplica trecho idêntico repetido dentro do mesmo job, sem perder o arquivo" do
      body = "Metodologia de diagnóstico do meio físico, biótico e socioeconômico da área. " * 10
      files = {
        "Proposta 25001.docx" => docx(body),
        "Doc´s Papyrus/Proposta 25001 copia.docx" => docx(body)
      }

      with_acervo("25001_Petrobras_Cetaceos" => files) do |path|
        jobs = Ingestion.new(path: path, classify: false).call

        documents = jobs.sole.documents
        assert_equal 2, documents.size, "os dois arquivos continuam no relatório"
        assert documents.any? { |doc| doc.chunks.any? }, "o primeiro fica com o trecho"
        assert documents.any? { |doc| doc.chunks.empty? }, "o segundo perde a cópia"
      end
    end

    test "arquivo ilegível entra no relatório com status, não derruba o lote" do
      files = {
        "Proposta 25001.docx" => docx("Escopo dos serviços ambientais do licenciamento. " * 10),
        "anexo quebrado.docx" => "isso não é um docx"
      }

      with_acervo("25001_Petrobras_Cetaceos" => files) do |path|
        documents = Ingestion.new(path: path, classify: false).call.sole.documents

        quebrado = documents.find { |doc| doc.item.filename == "anexo quebrado.docx" }
        assert_not quebrado.ok?
        assert_empty quebrado.chunks
        assert_not quebrado.indexable?
      end
    end

    test "limit corta a quantidade de jobs processados" do
      acervo = {
        "25001_Petrobras_Cetaceos" => { "Proposta 25001.docx" => docx("Texto do escopo ambiental. " * 10) },
        "25002_Renova_Estudos" => { "Proposta 25002.docx" => docx("Outro texto de escopo. " * 10) }
      }

      with_acervo(acervo) do |path|
        assert_equal 1, Ingestion.new(path: path, classify: false, limit: 1).call.size
      end
    end

    test "reporta progresso por job quando um bloco é passado" do
      seen = []
      progress = ->(index, total, job) { seen << [ index, total, job.numero ] }

      with_acervo("25001_Petrobras_Cetaceos" => { "Proposta 25001.docx" => docx("Escopo. " * 20) }) do |path|
        Ingestion.new(path: path, classify: false, &progress).call
      end

      assert_equal [ [ 1, 1, "25001" ] ], seen
    end

    private

    def docx(body_text)
      Zip::OutputStream.write_buffer do |zip|
        zip.put_next_entry("word/document.xml")
        zip.write(format(SECTION_XML, body: body_text))
      end.string
    end

    def with_acervo(jobs)
      Dir.mktmpdir do |root|
        jobs.each do |job_name, files|
          files.each do |relative, content|
            full = File.join(root, job_name, relative)
            FileUtils.mkdir_p(File.dirname(full))
            File.binwrite(full, content)
          end
        end

        yield root
      end
    end
  end
end
