require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "render_markdown converts basic markdown to sanitized HTML" do
    html = render_markdown("**Tipo de licença:** LP")

    assert_includes html, "<strong>Tipo de licença:</strong>"
  end

  test "render_markdown strips embedded raw HTML instead of rendering it (XSS protection)" do
    html = render_markdown("Texto <script>alert('x')</script> normal")

    assert_not_includes html, "<script>"
  end

  test "render_markdown adds a blank line before a list that has none, so Redcarpet renders it as a list" do
    html = render_markdown("**Diagnósticos:**\n* Fauna\n* Flora")

    assert_includes html, "<ul>"
    assert_includes html, "<li>Fauna</li>"
  end

  test "render_markdown returns an empty-safe string for nil input" do
    assert_equal "", render_markdown(nil)
  end

  test "render_markdown adds rel and target to links" do
    html = render_markdown("[INEMA](https://inema.ba.gov.br)")

    assert_includes html, 'rel="noopener noreferrer"'
    assert_includes html, 'target="_blank"'
  end

  test "flash_config returns the success config for notice and success" do
    assert_equal "text-success", flash_config("notice")[:text_class]
    assert_equal "bg-success", flash_config("notice")[:bar_class]
    assert_equal "text-success", flash_config("success")[:text_class]
  end

  test "flash_config returns the error config for alert and error" do
    assert_equal "text-error", flash_config("alert")[:text_class]
    assert_equal "text-error", flash_config("error")[:text_class]
  end

  test "flash_config returns the warning config for warning" do
    assert_equal "text-warning", flash_config("warning")[:text_class]
  end

  # Cobre os dois caminhos que gravam "kind" no metadata do blob: os anexos que o consultor sobe
  # (ConversationsController#attach_with_kind — et/tr/kmz/complementary) e os que a IA gera
  # (GenerateProposalDocumentTool#attach!/#attach_schedule_mspdi_files!).
  test "document_kind_label maps every kind written by ConversationsController and GenerateProposalDocumentTool to a short label" do
    proposal = proposals(:priced_proposal)

    {
      "et" => "ET", "tr" => "TR", "kmz" => "KMZ", "complementary" => "Complementar",
      "tecnica" => "Técnica", "comercial" => "Comercial", "combined" => "Técnica + Comercial",
      "schedule_mspdi_servico" => "MS Project · Serviço", "schedule_mspdi_implantacao" => "MS Project · Implantação"
    }.each do |kind, label|
      document = attach_generated_document(proposal, kind: kind)
      assert_equal label, document_kind_label(document)
    end
  end

  test "document_kind_label is nil for an attachment without a 'kind' in its metadata" do
    proposal = proposals(:priced_proposal)
    document = attach_generated_document(proposal, kind: nil)

    assert_nil document_kind_label(document)
  end

  test "flash_config falls back to the info config for an unknown flash type" do
    assert_equal ApplicationHelper::FLASH_TYPES["info"], flash_config("qualquer_coisa_desconhecida")
  end

  # CITAÇÃO INLINE. O código "[F12]" que a IA escreve no texto vira um chip que abre o trecho de
  # origem — é o que permite ao consultor perguntar "por que você concluiu isso?" sem sair do chat.
  class CitationRenderingTest < ActionView::TestCase
    tests ApplicationHelper

    setup do
      @conversation = conversations(:reviewing_conversation)
      @finding = @conversation.project_findings.create!(
        field: "orgao_ambiental", value: "INEMA", nature: "fato", source_kind: "tr",
        excerpt: "...protocolo junto ao INEMA...", locator: "item 2.1"
      )
    end

    test "um código válido vira chip que abre o popover do achado" do
      html = render_markdown("O órgão é o INEMA [F#{@finding.id}].", findings: [ @finding ])

      assert_includes html, "<button"
      assert_includes html, "F#{@finding.id}"
      assert_includes html, "popovertarget=\"citation_project_finding_#{@finding.id}\""
      assert_not_includes html, "[F#{@finding.id}]"
    end

    # Achado ao vivo (conversa 37, 2026-09): a IA quase sempre agrupa mais de um código no MESMO
    # colchete ("[F12, F34]") quando a frase se apoia em vários achados — vira UM chip por
    # código, não um chip só pro grupo inteiro.
    test "colchete com mais de um código vira um chip por código" do
      outro = @conversation.project_findings.create!(
        field: "municipios", value: "Icó/CE", nature: "fato", source_kind: "et", excerpt: "..."
      )

      html = render_markdown("Área em Icó [F#{@finding.id}, F#{outro.id}].", findings: [ @finding, outro ])

      assert_includes html, "popovertarget=\"citation_project_finding_#{@finding.id}\""
      assert_includes html, "popovertarget=\"citation_project_finding_#{outro.id}\""
      assert_not_includes html, "[F#{@finding.id}"
    end

    test "colchete agrupado com um código inválido e outro válido remove só o inválido" do
      html = render_markdown("Área [F#{@finding.id}, F999999].", findings: [ @finding ])

      assert_includes html, "popovertarget=\"citation_project_finding_#{@finding.id}\""
      assert_not_includes html, "F999999"
    end

    # Marca inventada renderizada como se fosse fonte é pior que nenhuma fonte: some do texto.
    test "código sem achado correspondente é removido do texto" do
      html = render_markdown("O órgão é o INEMA [F999999].", findings: [ @finding ])

      assert_includes html, "O órgão é o INEMA"
      assert_not_includes html, "F999999"
    end

    test "o popover mostra o trecho e a origem, escapados" do
      @finding.update!(excerpt: "<script>alert('x')</script>")
      html = render_citation_popovers([ @finding ])

      assert_includes html, "Termo de Referência"
      assert_includes html, "item 2.1"
      assert_not_includes html, "<script>"
    end

    test "texto sem citação nenhuma continua renderizando igual" do
      assert_includes render_markdown("**Tipo de licença:** LP"), "<strong>Tipo de licença:</strong>"
    end
  end

  private
    # Mesmo metadata que GenerateProposalDocumentTool#attach!/#attach_schedule_mspdi_files!
    # gravam de verdade — kind: nil simula um attachment sem essa chave (ex.: ET/KMZ enviado pelo
    # consultor, que não passa por essa ferramenta).
    def attach_generated_document(proposal, kind:)
      proposal.generated_documents.attach(
        io: StringIO.new("conteúdo"), filename: "doc.docx", content_type: "application/octet-stream",
        metadata: kind ? { kind: kind } : {}
      )
      proposal.generated_documents.last
    end
end
