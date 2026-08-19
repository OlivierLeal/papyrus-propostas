require "test_helper"

class GenerateProposalDocumentToolTest < ActiveSupport::TestCase
  NS = { "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main" }.freeze

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
      produtos: [ "EIA - Estudo de Impacto Ambiental", "RIMA - Relatório de Impacto Ambiental" ],
      descricao_revisao: "Ajuste de escopo conforme pedido do consultor"
    }
  end

  test "refuses to generate when the proposal is still a draft" do
    @proposal.update!(status: "draft")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    result = JSON.parse(tool.execute(**@args))

    assert result["error"].present?
    assert_not @proposal.generated_documents.attached?
    assert_equal 0, @proposal.reload.version # não consome número de versão quando recusa
  end

  test "attaches a single combined docx when document_split is combined" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    result = JSON.parse(tool.execute(**@args))

    assert result["success"]
    assert_equal 1, result["version"]
    assert_equal 1, @proposal.generated_documents.count
    assert_equal "proposta_tecnica_comercial.docx", @proposal.generated_documents.first.filename.to_s
    assert_equal "combined", @proposal.generated_documents.first.blob.metadata["kind"]
  end

  test "attaches two docx files when document_split is separated" do
    @proposal.update!(document_split: "separated")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    result = JSON.parse(tool.execute(**@args))

    assert result["success"]
    assert_equal 2, @proposal.generated_documents.count
    kinds = @proposal.generated_documents.map { |doc| doc.blob.metadata["kind"] }
    assert_includes kinds, "tecnica"
    assert_includes kinds, "comercial"
  end

  test "never lets the AI supply the price table, team names or proposal number" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    tool.execute(**@args)

    xml = document_xml(@proposal.generated_documents.first)

    assert_includes xml, @proposal.docx_numero_proposta
    assert_includes xml, "Pedro Almeida" # team_slot_for_docx, não veio dos args
  end

  test "the first generation always increments version to 1, tags the blob and ignores descricao_revisao (fica Emissão Inicial)" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    tool.execute(**@args)

    @proposal.reload
    document = @proposal.generated_documents.first
    assert_equal 1, @proposal.version
    assert_equal 1, document.blob.metadata["version"]
    assert_equal "Emissão Inicial", document.blob.metadata["description"]

    xml = document_xml(document)
    assert_includes xml, "Rev. 00"
    assert_includes xml, "Emissão Inicial"
  end

  test "a second generation bumps to version 2, uses the AI-supplied description and keeps the version 1 row in the revision table" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    tool.execute(**@args) # versão 1
    result = JSON.parse(tool.execute(**@args)) # versão 2

    @proposal.reload
    assert_equal 2, @proposal.version
    assert_equal 2, result["version"]

    current_document = @proposal.generated_documents.max_by { |d| d.blob.metadata["version"] }
    assert_equal 2, current_document.blob.metadata["version"]
    assert_equal "Ajuste de escopo conforme pedido do consultor", current_document.blob.metadata["description"]

    xml = document_xml(current_document)
    assert_includes xml, "Rev. 01"
    assert_includes xml, "Emissão Inicial" # linha da versão 1 continua na tabela
    assert_includes xml, "Ajuste de escopo conforme pedido do consultor"
  end

  test "the cover title matches the document: combined shows 'técnica e comercial', split shows only its own half" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)
    tool.execute(**@args)

    combined_xml = document_xml(@proposal.generated_documents.first)
    assert_includes combined_xml, "<w:t>TÉCNICA E</w:t>"
    assert_includes combined_xml, "<w:t>COMERCIAL</w:t>"

    @proposal.update!(document_split: "separated")
    tool.execute(**@args)
    @proposal.reload

    technical_xml = document_xml(@proposal.generated_documents.find { |d| d.blob.metadata["kind"] == "tecnica" })
    commercial_xml = document_xml(@proposal.generated_documents.find { |d| d.blob.metadata["kind"] == "comercial" })

    assert_includes technical_xml, "<w:t>TÉCNICA</w:t>"
    assert_not_includes technical_xml, "<w:t>COMERCIAL</w:t>"

    assert_includes commercial_xml, "<w:t>COMERCIAL</w:t>"
    assert_not_includes commercial_xml, "<w:t>TÉCNICA</w:t>"
  end

  test "returns a friendly error and attaches nothing when the filler raises" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(proposal: @proposal)

    # Minitest 6.0.6 não empacota minitest/mock nesta instalação (sem Object#stub),
    # então redefinimos o singleton method e restauramos no ensure — mesmo padrão do AiStubHelper.
    original_new = ProposalDocxFiller.method(:new)
    ProposalDocxFiller.define_singleton_method(:new) { |*| raise "boom" }

    begin
      result = JSON.parse(tool.execute(**@args))
      assert result["error"].present?
    ensure
      ProposalDocxFiller.define_singleton_method(:new, original_new)
    end

    assert_not @proposal.generated_documents.attached?
  end

  private
    def document_xml(document)
      Zip::File.open(ActiveStorage::Blob.service.path_for(document.blob.key)) { |zip| zip.read("word/document.xml") }.force_encoding("UTF-8")
    end
end
