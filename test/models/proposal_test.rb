require "test_helper"

class ProposalTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:reviewing_conversation)
  end

  test "requires a valid status" do
    proposal = proposals(:priced_proposal)
    proposal.status = "invalido"
    assert_not proposal.valid?
  end

  test "requires a valid document_split" do
    proposal = proposals(:priced_proposal)
    proposal.document_split = "invalido"
    assert_not proposal.valid?
  end

  test "build_from_template! copies the default hours from study_templates" do
    proposal = @conversation.create_proposal!(status: "draft")

    pricing = proposal.build_from_template!

    coordenacao = pricing.proposal_professionals.find_by(deliverable_name: "Coordenação geral")
    fauna = pricing.proposal_professionals.find_by(deliverable_name: "Diagnóstico de fauna e flora")

    assert_equal 40, coordenacao.hours_office
    assert_equal 0, coordenacao.hours_field
    assert_equal 30, fauna.hours_office
    assert_equal 48, fauna.hours_field
    assert pricing.total_value.positive?
  end

  test "build_with_ai_suggested_team! only accepts lines matching the study_templates menu" do
    proposal = @conversation.create_proposal!(status: "draft")

    ai_response = {
      linhas: [
        { professional_id: professionals(:coordenador).id, deliverable_name: "Coordenação geral", hours_office: 60, hours_field: 0 },
        { professional_id: 999_999, deliverable_name: "Profissional inventado", hours_office: 100, hours_field: 100 }
      ],
      documentos_separados: false
    }.to_json

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    assert_equal 1, pricing.proposal_professionals.count
    assert_equal 60, pricing.proposal_professionals.first.hours_office
    assert_equal "combined", proposal.reload.document_split
  end

  test "build_with_ai_suggested_team! sets document_split to separated when the AI flags it" do
    proposal = @conversation.create_proposal!(status: "draft")

    ai_response = { linhas: [], documentos_separados: true }.to_json

    stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    assert_equal "separated", proposal.reload.document_split
  end

  test "build_with_ai_suggested_team! falls back to the template when the AI reply is not valid JSON" do
    proposal = @conversation.create_proposal!(status: "draft")

    pricing = stub_ai_complete("isso não é json") { proposal.build_with_ai_suggested_team! }

    assert_equal 2, pricing.proposal_professionals.count
  end

  test "build_with_ai_suggested_team! strips markdown fences before parsing" do
    proposal = @conversation.create_proposal!(status: "draft")
    ai_response = "```json\n" + { linhas: [], documentos_separados: false }.to_json + "\n```"

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    # Nenhuma linha válida vinda da IA (vazio) cai no fallback do template.
    assert_equal 2, pricing.proposal_professionals.count
  end

  test "build_with_ai_suggested_team! falls back to the template when the AI call itself raises" do
    proposal = @conversation.create_proposal!(status: "draft")

    pricing = stub_ai_error { proposal.build_with_ai_suggested_team! }

    assert_equal 2, pricing.proposal_professionals.count
  end

  test "team_slot_for_docx returns the professional with the most office hours by default" do
    proposal = proposals(:priced_proposal)

    name, qualification = proposal.team_slot_for_docx

    assert_equal "Pedro Almeida", name
    assert_includes qualification, "Coordenador Técnico"
  end

  test "team_slot_for_docx matches a role hint case-insensitively" do
    proposal = proposals(:priced_proposal)

    name, = proposal.team_slot_for_docx(role_hint: "bióloga")

    assert_equal "Beth Ferreira", name
  end

  test "team_slot_for_docx returns blanks when there is no matching professional" do
    proposal = proposals(:priced_proposal)

    name, qualification = proposal.team_slot_for_docx(role_hint: "segurança do trabalho")

    assert_equal "", name
    assert_equal "", qualification
  end

  test "docx_price_rows lists every professional line plus logistics and external costs" do
    proposal = proposals(:priced_proposal)
    proposal.project_pricing.update!(external_costs: [ { "description" => "ART", "value" => 350 } ])

    rows = proposal.docx_price_rows

    descriptions = rows.map(&:first)
    assert_includes descriptions, "Pedro Almeida — Coordenação geral"
    assert_includes descriptions, "Beth Ferreira — Diagnóstico de fauna e flora"
    assert_includes descriptions, "ART"
    assert_includes descriptions, "Logística (deslocamento, hospedagem, alimentação)"
  end

  test "docx_payment_schedule_rows mirrors the computed payment schedule" do
    proposal = proposals(:priced_proposal)

    rows = proposal.docx_payment_schedule_rows

    assert_equal 4, rows.size
    assert_includes rows, [ "Assinatura do contrato", "30%" ]
  end

  test "docx_revision_rows has only the current row when nothing was generated before" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)

    rows = proposal.docx_revision_rows(current_description: "Emissão Inicial")

    assert_equal [ [ "00", "Emissão Inicial", Date.current.strftime("%d/%m/%Y") ] ], rows
  end

  test "docx_revision_rows keeps past versions (from generated_documents metadata) and appends the current one" do
    proposal = proposals(:priced_proposal)
    proposal.generated_documents.attach(
      io: StringIO.new("v1"), filename: "v1.docx", content_type: "application/octet-stream",
      metadata: { kind: "combined", version: 1, description: "Emissão Inicial" }
    )
    proposal.update!(version: 2)

    rows = proposal.docx_revision_rows(current_description: "Ajuste de escopo")

    assert_equal 2, rows.size
    assert_equal "00", rows[0][0]
    assert_equal "Emissão Inicial", rows[0][1]
    assert_equal [ "01", "Ajuste de escopo", Date.current.strftime("%d/%m/%Y") ], rows[1]
  end

  test "docx_numero_proposta combines prefix + 2-digit creation year + record id" do
    proposal = proposals(:priced_proposal)
    year = proposal.created_at.strftime("%y")

    assert_equal "PTC#{year}#{proposal.id}", proposal.docx_numero_proposta
    assert_equal "PTC#{year}#{proposal.id}", proposal.docx_numero_proposta("combined")
    assert_equal "PT#{year}#{proposal.id}", proposal.docx_numero_proposta("tecnica")
    assert_equal "PC#{year}#{proposal.id}", proposal.docx_numero_proposta("comercial")
  end

  test "docx_filename follows the real Papyrus naming pattern (número_cliente_RevNN.docx)" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)

    assert_equal "#{proposal.docx_numero_proposta('tecnica')}_#{proposal.conversation.client_name}_Rev00.docx",
      proposal.docx_filename("tecnica")
  end

  test "docx_filename sanitizes filesystem-unsafe characters from the client name" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)
    proposal.conversation.update!(client_name: "Cliente/Teste: \"Especial\"")

    assert_equal "#{proposal.docx_numero_proposta('combined')}_Cliente-Teste- -Especial-_Rev00.docx",
      proposal.docx_filename("combined")
  end
end
