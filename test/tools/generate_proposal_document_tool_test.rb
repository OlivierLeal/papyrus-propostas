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
    assert_equal [ @proposal.docx_filename("tecnica", municipio: @args[:municipios], estado: @args[:estado]) ], result["filenames"]
    assert_equal 1, @proposal.generated_documents.count
    document = @proposal.generated_documents.first
    assert_equal @proposal.docx_filename("tecnica", municipio: @args[:municipios], estado: @args[:estado]), document.filename.to_s
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
    assert_equal [ @proposal.docx_filename("combined", municipio: @args[:municipios], estado: @args[:estado]) ], result["filenames"]
    assert_equal 2, @proposal.generated_documents.count
  end

  test "attaches a single combined docx when document_split is combined" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    result = JSON.parse(tool.execute(**@args))

    assert result["success"]
    assert_equal 1, result["version"]
    assert_equal 1, @proposal.generated_documents.count
    assert_equal @proposal.docx_filename("combined", municipio: @args[:municipios], estado: @args[:estado]), @proposal.generated_documents.first.filename.to_s
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

    combined_texts = document_texts(@proposal.generated_documents.first)
    assert_includes combined_texts, "TÉCNICA E"
    assert_includes combined_texts, "COMERCIAL"

    @proposal.update!(document_split: "separated")
    tool.execute(**@args)
    @proposal.reload

    technical_texts = document_texts(@proposal.generated_documents.find { |d| d.blob.metadata["kind"] == "tecnica" })
    commercial_texts = document_texts(@proposal.generated_documents.find { |d| d.blob.metadata["kind"] == "comercial" })

    assert_includes technical_texts, "TÉCNICA"
    assert_not_includes technical_texts, "COMERCIAL"

    assert_includes commercial_texts, "COMERCIAL"
    assert_not_includes commercial_texts, "TÉCNICA"
  end

  test "the generated filename includes the escopo segment (tipo de estudo + município/UF vindos dos args da IA)" do
    @proposal.update!(document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    result = JSON.parse(tool.execute(**@args))

    assert_includes result["filenames"].first, "_RAP_Vitória da Conquista_BA_Rev."
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
    assert_includes result["error"], "processados"
    assert_nil conversation.reload.proposal
  end

  test "a missing study type says so, and where to fix it, instead of blaming document processing" do
    # Conversa 31, em produção: o ET estava "done" havia 15 minutos e o que faltava era cadastro de
    # tipo de estudo, mas o erro dizia "ET ainda em processamento" — a IA leu isso como falha de
    # backend, repetiu a chamada quatro vezes e mandou o consultor procurar o time de desenvolvimento.
    conversation = conversations(:reviewing_conversation)
    conversation.update!(study_type: nil)
    tool = GenerateProposalDocumentTool.new(conversation: conversation)

    result = JSON.parse(tool.execute(**@args))

    assert_includes result["error"], "TIPO DE ESTUDO"
    assert_includes result["error"], "NÃO repita esta chamada"
    assert_not_includes result["error"], "processamento"
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

    # Texto de cada <w:t>, para comparar CONTEÚDO em vez de XML cru: o modelo é reaberto e salvo
    # de tempos em tempos pela Papyrus, e o salvamento mexe na forma da tag (ex.: passa a gravar
    # xml:space="preserve"), o que quebrava asserção feita em cima da string "<w:t>X</w:t>".
    def document_texts(document)
      Nokogiri::XML(document_xml(document))
        .xpath("//w:t", "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
        .map { |node| node.text.strip }
    end

    # Linhas de dados do Quadro 6-1 (produtos) — a tabela de índice 1 no modelo.
    def product_rows(document)
      ns = { "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main" }
      tabela = Nokogiri::XML(document_xml(document)).xpath("//w:tbl", ns)[1]
      tabela.xpath(".//w:tr", ns)[1..].map do |linha|
        linha.xpath(".//w:tc", ns).map { |celula| celula.xpath(".//w:t", ns).map(&:text).join.strip }
      end
    end

    def zip_entry_names(document)
      Zip::File.open(ActiveStorage::Blob.service.path_for(document.blob.key)) { |zip| zip.entries.map(&:name) }
    end


  # NOME DITADO PELO CONSULTOR. Ele já criou a pasta na rede e lançou a proposta no controle com
  # um nome; o arquivo tem que sair com aquele nome, não com o que o sistema montaria.
  test "uses the filename the consultant dictated in the chat" do
    @proposal.update!(status: "priced", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    result = JSON.parse(tool.execute(**@args.merge(nome_arquivo: "PTC26002_PMM_LU_Simões Filho_BA")))

    assert_equal [ "PTC26002_PMM_LU_Simões Filho_BA_Rev.00.docx" ], result["filenames"]
    assert_equal "PTC26002_PMM_LU_Simões Filho_BA_Rev.00.docx", @proposal.generated_documents.first.filename.to_s
  end

  # "Comece a utilizar": ele disse o nome uma vez, não uma vez por geração.
  test "keeps using the dictated name on the next generation, without being told again" do
    @proposal.update!(status: "priced", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)
    tool.execute(**@args.merge(nome_arquivo: "PTC26002_PMM_LU"))

    result = JSON.parse(tool.execute(**@args))

    assert_equal [ "PTC26002_PMM_LU_Rev.01.docx" ], result["filenames"]
  end

  test "the dictated name distinguishes técnica from comercial when the proposal is split" do
    @proposal.update!(status: "priced", document_split: "separated")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    result = JSON.parse(tool.execute(**@args.merge(nome_arquivo: "PTC26002_PMM_LU")))

    assert_equal [ "PT26002_PMM_LU_Rev.00.docx", "PC26002_PMM_LU_Rev.00.docx" ], result["filenames"]
  end

  test "without a dictated name the system pattern is used, as before" do
    @proposal.update!(status: "priced", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    result = JSON.parse(tool.execute(**@args))

    assert_equal [ @proposal.docx_filename("combined", municipio: @args[:municipios], estado: @args[:estado]) ],
                 result["filenames"]
    assert_nil @proposal.reload.docx_filename_override
  end

  test "\"padrão\" gives the naming back to the system" do
    @proposal.update!(status: "priced", document_split: "combined", docx_filename_override: "PTC26002_PMM_LU")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args.merge(nome_arquivo: "padrão"))

    assert_nil @proposal.reload.docx_filename_override
  end


  # TÓPICOS DO ESCOPO (2026-08). O escopo de estudos com divisão temática (meio físico, biótico,
  # socioeconômico...) saía tudo em texto corrido, sem numeração — pedido do consultor pra sair
  # "5.1", "5.2" etc., como o resto do documento.
  test "numera e negrita cada tópico do escopo, na ordem enviada" do
    @proposal.update!(status: "priced", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args.merge(topicos_escopo: [
      "Meio Físico | Caracterização climática e geomorfológica.",
      "Meio Biótico | Mapeamento da cobertura vegetal."
    ]))

    doc = Nokogiri::XML(document_xml(@proposal.generated_documents.first))
    titulo1 = doc.xpath("//w:t").find { |t| t.text == "5.1 MEIO FÍSICO" }
    titulo2 = doc.xpath("//w:t").find { |t| t.text == "5.2 MEIO BIÓTICO" }
    corpo1 = doc.xpath("//w:t").find { |t| t.text == "Caracterização climática e geomorfológica." }

    assert titulo1.present?, "esperava o subtítulo numerado 5.1"
    assert titulo1.at_xpath("ancestor::w:r/w:rPr/w:b", NS).present?, "esperava o subtítulo em negrito"
    assert titulo2.present?, "esperava o subtítulo numerado 5.2"
    assert corpo1.present?
    assert_not corpo1.at_xpath("ancestor::w:r/w:rPr/w:b", NS).present?, "o texto do tópico não deveria vir em negrito"
  end

  test "não sobra bloco de tópicos quando topicos_escopo não é enviado" do
    @proposal.update!(status: "priced", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args)

    xml = document_xml(@proposal.generated_documents.first)
    assert_not_includes xml, "5.1"
  end

  # ITENS NÃO PREVISTOS. Toda proposta validada pela Papyrus fecha o escopo com o que ela NÃO
  # cobre; nas geradas pelo sistema essa lista simplesmente não existia.
  test "o escopo termina com os itens não previstos e a ressalva de proposta complementar" do
    @proposal.update!(status: "priced", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args.merge(itens_nao_previstos: [ "Execução dos planos e programas ambientais", "Regularização fundiária" ]))

    xml = document_xml(@proposal.generated_documents.first)
    assert_includes xml, "Itens não previstos"
    assert_includes xml, "Execução dos planos e programas ambientais"
    assert_includes xml, "Regularização fundiária"
    assert_includes xml, "serão objeto de proposta complementar"
  end

  # A ressalva é proteção comercial: não pode depender de a IA lembrar de mandá-la.
  test "a ressalva de proposta complementar sai mesmo quando a IA não lista nenhum item" do
    @proposal.update!(status: "priced", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args)

    assert_includes document_xml(@proposal.generated_documents.first), "serão objeto de proposta complementar"
  end

  # OBRIGAÇÕES ADICIONAIS. Quando o ET/TR pede algo específico de uma das partes além do que já é
  # fixo no modelo (7.1/7.2), a IA identifica e a ferramenta acrescenta como item novo na lista.
  test "acrescenta as obrigações adicionais da contratante e da papyrus quando informadas" do
    @proposal.update!(status: "priced", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args.merge(
      obrigacoes_contratante_adicionais: [ "Fornecer escolta armada para as vistorias de campo." ],
      obrigacoes_papyrus_adicionais: [ "Emitir relatório mensal de acompanhamento ao órgão financiador." ]
    ))

    xml = document_xml(@proposal.generated_documents.first)
    assert_includes xml, "Fornecer escolta armada para as vistorias de campo."
    assert_includes xml, "Emitir relatório mensal de acompanhamento ao órgão financiador."
  end

  # A maioria das propostas não tem obrigação extra nenhuma — o item de lista não pode ficar
  # visível em branco no documento final (ver ProposalDocxFiller#fill_simple_placeholders!).
  test "não deixa item de obrigação em branco quando não há nada adicional" do
    @proposal.update!(status: "priced", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args)

    xml = document_xml(@proposal.generated_documents.first)
    assert_not_includes xml, "OBRIGACOES_CONTRATANTE_ADICIONAIS"
    assert_not_includes xml, "OBRIGACOES_PAPYRUS_ADICIONAIS"
  end

  test "o formato de cada produto vem da IA, com padrão quando ela não informa" do
    @proposal.update!(status: "priced", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args.merge(produtos: [ "Inventário Florestal | Word e PDF", "Certificado LP | PDF", "Mapa temático" ]))

    linhas = product_rows(@proposal.generated_documents.first)
    assert_includes linhas, [ "Inventário Florestal", "Word e PDF" ]
    assert_includes linhas, [ "Certificado LP", "PDF" ]
    assert_includes linhas, [ "Mapa temático", "Digital (PDF)" ]
  end

  # A Papyrus separa os produtos por fase do licenciamento (LP / LI-ASV-AMF), com uma linha de
  # agrupamento sem formato.
  test "um produto terminado em dois-pontos vira linha de agrupamento por fase" do
    @proposal.update!(status: "priced", document_split: "combined")
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args.merge(produtos: [ "Licença Prévia (LP):", "Estudo de Médio Impacto (EMI) | Word e PDF" ]))

    linhas = product_rows(@proposal.generated_documents.first)
    assert_equal [ "Licença Prévia (LP):", "" ], linhas.first
    assert_equal [ "Estudo de Médio Impacto (EMI)", "Word e PDF" ], linhas.second
  end

  # Achado ao vivo em produção: a IA "vazou" códigos de citação do chat ([F12], só fazem
  # sentido lá — ver Message::CITATION_PATTERN) pro texto de uma proposta real, e eles saíram
  # crus no .docx que o cliente lê ("mediante elaboração de [F681] Estudo Ambiental...").
  test "strips leftover [F12]-style citation codes from any text param, collapsing the extra space" do
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args.merge(
      objetivo_dos_servicos: "Assessorar mediante elaboração de [F681] Estudo Ambiental Intermediário (EAI), " \
        "incluindo [F680] [F686] avaliação arqueológica Nível 3 com Anuência Final do IPHAN."
    ))

    xml = document_xml(@proposal.generated_documents.first)
    assert_not_includes xml, "[F681]"
    assert_not_includes xml, "[F680]"
    assert_not_includes xml, "[F686]"
    assert_includes document_texts(@proposal.generated_documents.first).join(" "),
      "Assessorar mediante elaboração de Estudo Ambiental Intermediário (EAI), incluindo avaliação arqueológica " \
      "Nível 3 com Anuência Final do IPHAN."
  end

  test "strips citation codes from array params too (topicos_escopo, produtos, itens_nao_previstos)" do
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args.merge(
      topicos_escopo: [ "Diagnóstico [F12] | Levantamento de campo conforme [F13] estabelecido." ],
      produtos: [ "Relatório [F14] | Digital (PDF)" ],
      itens_nao_previstos: [ "Regularização fundiária [F15]" ]
    ))

    xml = document_xml(@proposal.generated_documents.first)
    assert_not_includes xml, "[F12]"
    assert_not_includes xml, "[F13]"
    assert_not_includes xml, "[F14]"
    assert_not_includes xml, "[F15]"
    assert_includes document_texts(@proposal.generated_documents.first).join(" "), "Regularização fundiária"
  end

  test "includes the schedule table when the pricing has items and a start date" do
    pricing = @proposal.project_pricing
    pricing.update!(schedule_papyrus_start_date: Date.new(2026, 9, 1))
    pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização", activity_name: "Assinatura do Contrato",
      start_period: 1, duration_periods: 1, position: 0)
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args)

    xml = document_xml(@proposal.generated_documents.first)
    assert_includes xml, "Quadro 9-1: Cronograma do Serviço."
    assert_includes xml, "Mobilização"
  end

  test "leaves out a schedule type that has items but no start date set" do
    pricing = @proposal.project_pricing
    pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização", activity_name: "Assinatura do Contrato",
      start_period: 1, duration_periods: 1, position: 0)
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args)

    assert_not_includes document_xml(@proposal.generated_documents.first), "Cronograma"
  end

  test "leaves out a schedule type that has a start date but no items" do
    @proposal.project_pricing.update!(schedule_papyrus_start_date: Date.new(2026, 9, 1))
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args)

    assert_not_includes document_xml(@proposal.generated_documents.first), "Cronograma"
  end

  test "numbers both quadros when both schedule types are present" do
    pricing = @proposal.project_pricing
    pricing.update!(schedule_papyrus_start_date: Date.new(2026, 9, 1), schedule_empreendimento_start_date: Date.new(2026, 9, 1))
    pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização", activity_name: "Contrato",
      start_period: 1, duration_periods: 1, position: 0)
    pricing.schedule_items.create!(schedule_type: "implantacao", phase_name: "Construção", activity_name: "Obras civis",
      start_period: 1, duration_periods: 6, position: 0)
    tool = GenerateProposalDocumentTool.new(conversation: @proposal.conversation)

    tool.execute(**@args)

    xml = document_xml(@proposal.generated_documents.first)
    assert_includes xml, "Quadro 9-1: Cronograma do Serviço."
    assert_includes xml, "Quadro 9-2: Cronograma de Implantação do Empreendimento."
  end
end
