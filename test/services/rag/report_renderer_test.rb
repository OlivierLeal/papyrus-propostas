require "test_helper"

module Rag
  # O relatório de conferência é HTML puro montado a partir dos structs de Ingestion (nada de
  # banco). Os testes montam os structs à mão e conferem que o texto integral de cada trecho sai
  # no HTML, que o conteúdo é escapado, e que os rótulos de papel/sensível/revisão antiga
  # aparecem.
  class ReportRendererTest < ActiveSupport::TestCase
    test "monta um documento HTML com título, origem e aviso de que nada foi gravado" do
      html = ReportRenderer.new([ job([ document ]) ], source: "/acervo/amostra").call

      assert_match(/\A\s*<!doctype html>/i, html)
      assert_includes html, "<title>Acervo RAG — Papyrus</title>"
      assert_includes html, "/acervo/amostra"
      assert_includes html, "Nada foi gravado no banco"
    end

    test "os cards de resumo contam jobs, documentos e trechos" do
      jobs = [ job([ document(chunks: [ chunk, chunk(position: 1) ]) ]) ]

      html = ReportRenderer.new(jobs, source: "x").call

      assert_includes html, "<div class='card'><b>1</b><span>jobs</span></div>"
      assert_includes html, "<div class='card'><b>1</b><span>documentos</span></div>"
      assert_includes html, "<div class='card'><b>2</b><span>trechos</span></div>"
    end

    test "renderiza o texto integral de cada trecho, não só estatística" do
      texto = "Diagnóstico do meio físico conforme metodologia consagrada da Papyrus."
      html = ReportRenderer.new([ job([ document(chunks: [ chunk(content: texto) ]) ]) ], source: "x").call

      assert_includes html, texto
    end

    test "escapa o conteúdo do trecho (nunca injeta HTML do acervo cru)" do
      html = ReportRenderer.new([ job([ document(chunks: [ chunk(content: "<script>alert(1)</script>") ]) ]) ], source: "x").call

      assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert_not_includes html, "<script>alert(1)</script>"
    end

    test "trecho sensível ganha a classe e o motivo, e continua no HTML (o blur é CSS)" do
      sensivel = chunk(content: "CPF 000.000.000-00", sensitive: true, sensitivity_reasons: [ "cpf" ])
      html = ReportRenderer.new([ job([ document(chunks: [ sensivel ]) ]) ], source: "x").call

      assert_includes html, 'class="chunk sensitive"'
      assert_includes html, "sensível: cpf"
      assert_includes html, "CPF 000.000.000-00"
    end

    test "documento marcado como revisão antiga aparece com a flag e no contador" do
      antigo = document(superseded: true)
      html = ReportRenderer.new([ job([ antigo ]) ], source: "x").call

      assert_includes html, "revisão antiga"
      assert_includes html, "<div class='card'><b>1</b><span>revisões antigas (fora do índice)</span></div>"
    end

    test "documento sem texto nativo mostra o rótulo do status" do
      escaneado = document(status: :needs_ocr, chunks: [])
      html = ReportRenderer.new([ job([ escaneado ]) ], source: "x").call

      assert_includes html, "escaneado, sem OCR"
    end

    test "a barra de papéis mostra a tag do papel do documento" do
      html = ReportRenderer.new([ job([ document(role: "tr_cliente") ]) ], source: "x").call

      assert_includes html, ">tr_cliente</span>"
    end

    private

    def job(documents)
      Ingestion::Job.new(name: "25001_Petrobras_Cetaceos", numero: "25001",
        client_name: "Petrobras", subject: "Cetáceos", documents: documents)
    end

    def document(chunks: nil, role: "proposta_papyrus", status: :ok, superseded: false)
      Ingestion::Document.new(
        item: item(superseded: superseded), status: status, role: role, role_source: :heuristic,
        page_count: 3, chars_per_page: 900, chunks: chunks || [ chunk ],
        pricing_sheet_rows: 0, error: nil
      )
    end

    def item(superseded: false)
      Inventory::Item.new(
        path: "/acervo/25001_Petrobras/proposta.docx", filename: "proposta.docx",
        relative_path: "25001_Petrobras/proposta.docx", sha256: "a" * 64, byte_size: 10,
        extension: "docx", numero_proposta: "25001", revision: 0, year: 2025,
        superseded: superseded, spreadsheet_path: nil
      )
    end

    def chunk(position: 0, content: "Trecho do escopo dos serviços ambientais.", sensitive: false, sensitivity_reasons: [])
      Ingestion::Chunk.new(
        position: position, section_number: "4", section_title: "ESCOPO",
        content: content, char_count: content.length, estimated_tokens: (content.length / 3.8).round,
        sensitive: sensitive, contains_pricing: false, sensitivity_reasons: sensitivity_reasons
      )
    end
  end
end
