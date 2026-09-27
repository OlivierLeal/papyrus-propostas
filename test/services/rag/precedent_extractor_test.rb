require "test_helper"

class Rag::PrecedentExtractorTest < ActiveSupport::TestCase
  setup do
    @proposal = HistoricalProposal.create!(
      job_name: "25010_Brava_Plantio", job_number: "25010", client_name: "Brava", year: 2025,
      source_path: "/x/pt25010.docx", relative_path: "pt25010.docx", filename: "PT25010_Rev01.docx",
      source_sha256: Digest::SHA256.hexdigest("pt25010"), chunker_version: Rag::Indexer::PIPELINE_VERSION,
      role: "proposta_papyrus", role_source: "ai", status: "ok", revision: "1"
    )
    @proposal.chunks.create!(position: 0, content: "OBJETIVO: plantio de mudas nativas em duas fazendas.")
    @proposal.chunks.create!(position: 9, section_title: "EQUIPE TÉCNICA", content: "Coordenador de Projetos | 9 horas")
    @proposal.chunks.create!(position: 10, section_title: "ANEXO", content: "texto irrelevante sem nada")
  end

  AI_REPLY = {
    servico: "Plantio de mudas nativas", tipos_estudo: [ "Plantio" ], atos_licenciamento: [],
    empreendimento: "Fazendas", local: "Candeias/BA", valor_total: "R$ 21.843,98", prazo: "12 meses",
    equipe: [ { funcao: "Coordenador de Projetos", horas_homem: 9, diarias: nil }, { funcao: "" } ],
    outros_custos: [ { descricao: "ART", valor: "R$ 99,64" } ], bdi: "1,20", impostos: nil,
    logistica: [ { descricao: "Hospedagem", valor: 1500 } ]
  }.to_json

  test "transcreve a ficha do job, converte valores em reais e embeda o descritor" do
    prompts = []
    precedent = with_chat_capturing(prompts, AI_REPLY) { stub_embedder { Rag::PrecedentExtractor.new("25010").call } }

    assert_equal "ok", precedent.status
    assert_equal BigDecimal("21843.98"), precedent.total_value
    assert_equal [ { "funcao" => "Coordenador de Projetos", "horas_homem" => "9.0" } ], precedent.team.map { |m| m.transform_values(&:to_s) }
    assert_equal BigDecimal("1.20"), BigDecimal(precedent.pricing_details["bdi"].to_s)
    assert_equal "ART", precedent.other_costs.first["descricao"]
    assert_includes precedent.descriptor, "empreendimento: Fazendas"
    assert precedent.embedding.present?
    assert_includes prompts.first, "Coordenador de Projetos | 9 horas", "seção de equipe entra no prompt"
    assert_includes prompts.first, "OBJETIVO: plantio", "início da proposta entra no prompt"
  end

  test "lê a planilha de precificação vinculada quando o arquivo existe" do
    Tempfile.create([ "25010_Planilha", ".xlsx" ]) do |file|
      File.binwrite(file.path, xlsx_bytes)
      @proposal.update!(spreadsheet_path: file.path)
      prompts = []

      precedent = with_chat_capturing(prompts, AI_REPLY) { stub_embedder { Rag::PrecedentExtractor.new("25010").call } }

      assert precedent.from_spreadsheet
      assert_includes prompts.first, "PLANILHA DE PRECIFICAÇÃO DO JOB"
      assert_includes prompts.first, "## Planilha: Orçamento"
    end
  end

  test "job sem proposta da Papyrus fica como no_data, sem chamar a IA" do
    precedent = assert_no_ai_calls { Rag::PrecedentExtractor.new("99999").call }

    assert_equal "no_data", precedent.status
  end

  test "resposta que não é JSON fica registrada como failed" do
    precedent = stub_rag_chat("não sei") { stub_embedder { Rag::PrecedentExtractor.new("25010").call } }

    assert_equal "failed", precedent.status
  end

  private

  def with_chat_capturing(prompts, reply)
    chat = Object.new
    chat.define_singleton_method(:ask) { |prompt| prompts << prompt; Struct.new(:content).new(reply) }
    stub_class_method(RubyLLM, :chat, ->(*) { chat }) { yield }
  end
end
