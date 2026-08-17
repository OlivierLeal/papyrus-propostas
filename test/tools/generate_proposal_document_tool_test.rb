require "test_helper"

class GenerateProposalDocumentToolTest < ActiveSupport::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @args = {
      nome_cliente: "Serra Verde Energias Renováveis S.A.",
      contato_cliente: "João Mendes",
      descricao_servico: "elaboração de EIA/RIMA",
      municipios: "Vitória da Conquista",
      estado: "BA",
      cnpj_cliente: "12.345.678/0001-90",
      objetivo_dos_servicos: "Obter a Licença Prévia junto ao INEMA.",
      caracterizacao_do_empreendimento: "Parque eólico com 24 aerogeradores.",
      nome_documento_tr: "Termo de Referência EIA-RIMA",
      escopo_e_metodologia: "Diagnósticos dos meios físico, biótico e socioeconômico.",
      prazo_de_execucao: "120 dias corridos",
      produtos: [ "EIA - Estudo de Impacto Ambiental", "RIMA - Relatório de Impacto Ambiental" ]
    }
  end

  test "refuses to generate when the proposal is still a draft" do
    @proposal.update!(status: "draft")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    result = tool.execute(**@args)

    assert result[:error].present?
    assert_not @proposal.generated_documents.attached?
  end

  test "attaches a single combined docx when document_split is combined" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    result = tool.execute(**@args)

    assert result[:success]
    assert_equal 1, @proposal.generated_documents.count
    assert_equal "proposta_tecnica_comercial.docx", @proposal.generated_documents.first.filename.to_s
    assert_equal "combined", @proposal.generated_documents.first.blob.metadata["kind"]
  end

  test "attaches two docx files when document_split is separated" do
    @proposal.update!(document_split: "separated")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    result = tool.execute(**@args)

    assert result[:success]
    assert_equal 2, @proposal.generated_documents.count
    kinds = @proposal.generated_documents.map { |doc| doc.blob.metadata["kind"] }
    assert_includes kinds, "tecnica"
    assert_includes kinds, "comercial"
  end

  test "never lets the AI supply the price table, team names or proposal number" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    tool.execute(**@args)

    document = @proposal.generated_documents.first
    xml = Zip::File.open(ActiveStorage::Blob.service.path_for(document.blob.key)) { |zip| zip.read("word/document.xml") }.force_encoding("UTF-8")

    assert_includes xml, @proposal.docx_numero_proposta
    assert_includes xml, "Pedro Almeida" # team_slot_for_docx, não veio dos args
  end

  test "returns a friendly error and attaches nothing when the filler raises" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    # Minitest 6.0.6 não empacota minitest/mock nesta instalação (sem Object#stub),
    # então redefinimos o singleton method e restauramos no ensure — mesmo padrão do AiStubHelper.
    original_new = ProposalDocxFiller.method(:new)
    ProposalDocxFiller.define_singleton_method(:new) { |*| raise "boom" }

    begin
      result = tool.execute(**@args)
      assert result[:error].present?
    ensure
      ProposalDocxFiller.define_singleton_method(:new, original_new)
    end

    assert_not @proposal.generated_documents.attached?
  end
end
