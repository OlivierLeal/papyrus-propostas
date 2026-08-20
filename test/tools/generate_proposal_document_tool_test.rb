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

  test "generates only the technical docx when the proposal is still a draft (pricing not approved yet)" do
    @proposal.update!(status: "draft", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    result = JSON.parse(tool.execute(**@args))

    assert result["success"]
    assert_equal [ @proposal.docx_filename("tecnica") ], result["filenames"]
    assert_equal 1, @proposal.generated_documents.count
    document = @proposal.generated_documents.first
    assert_equal @proposal.docx_filename("tecnica"), document.filename.to_s
    assert_equal "tecnica", document.blob.metadata["kind"]

    xml = document_xml(document)
    assert_includes xml, "Obter a Licença Prévia junto ao INEMA." # texto técnico preenchido normalmente
    assert_not_includes xml, "PREÇO E CONDIÇÕES DE PAGAMENTO" # seção comercial não existe nesse arquivo
  end

  test "still refuses nothing and always increments version, even across the draft -> priced transition" do
    @proposal.update!(status: "draft", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)
    tool.execute(**@args) # versão 1, só técnica

    @proposal.update!(status: "priced")
    result = JSON.parse(tool.execute(**@args)) # versão 2, documento completo

    assert result["success"]
    assert_equal 2, result["version"]
    assert_equal [ @proposal.docx_filename("combined") ], result["filenames"]
    assert_equal 2, @proposal.generated_documents.count
  end

  test "attaches a single combined docx when document_split is combined" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    result = JSON.parse(tool.execute(**@args))

    assert result["success"]
    assert_equal 1, result["version"]
    assert_equal 1, @proposal.generated_documents.count
    assert_equal @proposal.docx_filename("combined"), @proposal.generated_documents.first.filename.to_s
    assert_equal "combined", @proposal.generated_documents.first.blob.metadata["kind"]
  end

  test "attaches two docx files when document_split is separated" do
    @proposal.update!(document_split: "separated")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    result = JSON.parse(tool.execute(**@args))

    assert result["success"]
    assert_equal 2, @proposal.generated_documents.count
    kinds = @proposal.generated_documents.map { |doc| doc.blob.metadata["kind"] }
    assert_includes kinds, "tecnica"
    assert_includes kinds, "comercial"
  end

  test "never lets the AI supply the price table, team names or proposal number" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args)

    xml = document_xml(@proposal.generated_documents.first)

    assert_includes xml, @proposal.docx_numero_proposta
    assert_includes xml, "Pedro Almeida" # team_slot_for_docx, não veio dos args
  end

  test "the first generation always increments version to 1, tags the blob and ignores descricao_revisao (fica Emissão Inicial)" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

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
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

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
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)
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

  test "the proposal number uses the right prefix per variant: PTC combined, PT/PC when separated" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)
    tool.execute(**@args)

    combined_xml = document_xml(@proposal.generated_documents.first)
    assert_includes combined_xml, @proposal.docx_numero_proposta("combined")

    @proposal.update!(document_split: "separated")
    tool.execute(**@args)
    @proposal.reload

    technical_xml = document_xml(@proposal.generated_documents.find { |d| d.blob.metadata["kind"] == "tecnica" && d.blob.metadata["version"] == @proposal.version })
    commercial_xml = document_xml(@proposal.generated_documents.find { |d| d.blob.metadata["kind"] == "comercial" && d.blob.metadata["version"] == @proposal.version })

    assert_includes technical_xml, @proposal.docx_numero_proposta("tecnica")
    assert_not_includes technical_xml, @proposal.docx_numero_proposta("combined")
    assert_includes commercial_xml, @proposal.docx_numero_proposta("comercial")
  end

  test "embeds the real Mapbox map in the docx when the geospatial result has a PNG area_image" do
    @proposal.update!(document_split: "combined")
    attach_area_image!("image/png")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args)

    xml = document_xml(@proposal.generated_documents.first)
    assert_includes xml, "rId_MAPA_AREA_ESTUDO"
    assert_not_includes xml, "{{MAPA_AREA_ESTUDO}}"
    assert_includes zip_entry_names(@proposal.generated_documents.first), "word/media/mapa_area_estudo.png"
  end

  test "leaves the map placeholder blank when there's no PNG area_image (SVG croqui fallback or no geospatial_result at all)" do
    @proposal.update!(document_split: "combined")
    attach_area_image!("image/svg+xml")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args)

    xml = document_xml(@proposal.generated_documents.first)
    assert_not_includes xml, "rId_MAPA_AREA_ESTUDO"
    assert_not_includes xml, "{{MAPA_AREA_ESTUDO}}"
  end

  # Achado na prática: exigir clicar em "Avançar para Precificação" antes de QUALQUER geração,
  # inclusive só-técnica, não fazia sentido pro consultor ("não quero avançar pra preço ainda").
  test "auto-creates the proposal and AI-suggested team when none exists yet, then generates the technical docx" do
    conversation = conversations(:reviewing_conversation)
    assert_nil conversation.proposal
    tool = GenerateProposalDocumentTool.new(conversation: conversation)

    result = stub_ai_complete('{"linhas": [], "documentos_separados": false}') { JSON.parse(tool.execute(**@args)) }

    assert result["success"], result.inspect
    conversation.reload
    assert conversation.proposal.present?
    assert_equal "draft", conversation.proposal.status
    assert_equal "pricing", conversation.status
    assert_equal 1, conversation.proposal.generated_documents.count
  end

  test "returns a friendly error instead of hallucinating when the proposal can't be created yet" do
    conversation = conversations(:processing_conversation) # status "processing", ainda não é "reviewing"
    tool = GenerateProposalDocumentTool.new(conversation: conversation)

    result = JSON.parse(tool.execute(**@args))

    assert result["error"].present?
    assert_nil conversation.reload.proposal
  end

  test "broadcasts a refresh after successfully attaching a generated document, so the sidebar updates without F5" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    broadcasted = false
    original = Conversation.instance_method(:broadcast_refresh)
    Conversation.define_method(:broadcast_refresh) { broadcasted = true }

    begin
      tool.execute(**@args)
    ensure
      Conversation.define_method(:broadcast_refresh, original)
    end

    assert broadcasted
  end

  test "returns a friendly error and attaches nothing when the filler raises" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

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
    # PNG mínimo (1x1) válido — só precisa abrir como imagem de verdade, não importa o conteúdo.
    PNG_1X1 = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")

    def attach_area_image!(content_type)
      result = @proposal.conversation.create_geospatial_result!(area_ha: 10.0, perimeter_km: 1.0)
      bytes = content_type == "image/png" ? PNG_1X1 : "<svg></svg>"
      result.area_image.attach(io: StringIO.new(bytes), filename: "area.#{content_type == 'image/png' ? 'png' : 'svg'}", content_type: content_type)
    end

    def document_xml(document)
      Zip::File.open(ActiveStorage::Blob.service.path_for(document.blob.key)) { |zip| zip.read("word/document.xml") }.force_encoding("UTF-8")
    end

    def zip_entry_names(document)
      Zip::File.open(ActiveStorage::Blob.service.path_for(document.blob.key)) { |zip| zip.entries.map(&:name) }
    end
end
