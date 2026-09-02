require "test_helper"

class ProposalTest < ActiveSupport::TestCase
  include ActionView::Helpers::NumberHelper
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

    # 2, não 1: a diretora (always_included) entra sozinha via ensure_always_included_lines!,
    # mesmo não estando nas linhas que a IA sugeriu.
    assert_equal 2, pricing.proposal_professionals.count
    assert_equal 60, pricing.proposal_professionals.find_by(deliverable_name: "Coordenação geral").hours_office
    assert_equal "combined", proposal.reload.document_split
  end

  # A linha fora do cadastro continua fora da precificação, mas para de sumir em silêncio: ou
  # falta cadastro, ou a IA inventou, e as duas coisas são informação para o consultor.
  test "build_with_ai_suggested_team! sinaliza a linha que ficou fora do cadastro" do
    proposal = @conversation.create_proposal!(status: "draft")

    ai_response = {
      linhas: [
        { professional_id: professionals(:coordenador).id, deliverable_name: "Coordenação geral", hours_office: 60, hours_field: 0 },
        { professional_id: 999_999, deliverable_name: "Arqueólogo sênior", hours_office: 100, hours_field: 100 }
      ],
      documentos_separados: false
    }.to_json

    stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    flag = @conversation.project_findings.find_by(nature: "sugestao")
    assert_includes flag.value, "fora do cadastro"
    assert_includes flag.value, "Arqueólogo sênior"
    assert_equal "sistema", flag.source_kind
  end

  test "build_with_ai_suggested_team! sets document_split to separated when the AI flags it" do
    proposal = @conversation.create_proposal!(status: "draft")

    ai_response = { linhas: [], documentos_separados: true }.to_json

    stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    assert_equal "separated", proposal.reload.document_split
  end

  test "build_with_ai_suggested_team! includes an always_included professional even with all-zero default hours and no AI line for them" do
    proposal = @conversation.create_proposal!(status: "draft")

    ai_response = {
      linhas: [ { professional_id: professionals(:coordenador).id, deliverable_name: "Coordenação geral", hours_office: 60, hours_field: 0 } ],
      documentos_separados: false
    }.to_json

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    diretora_line = pricing.proposal_professionals.find_by(professional: professionals(:diretora))
    assert diretora_line.present?
    assert_equal 0, diretora_line.hours_office
    assert_equal 0, diretora_line.hours_field
  end

  test "build_with_ai_suggested_team! keeps the AI's real hours for an always_included professional instead of overwriting with the zero default" do
    proposal = @conversation.create_proposal!(status: "draft")

    ai_response = {
      linhas: [ { professional_id: professionals(:diretora).id, deliverable_name: "Direção de Negócios", hours_office: 15, hours_field: 0 } ],
      documentos_separados: false
    }.to_json

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    assert_equal 1, pricing.proposal_professionals.where(professional: professionals(:diretora)).count
    assert_equal 15, pricing.proposal_professionals.find_by(professional: professionals(:diretora)).hours_office
  end

  # BUG achado comparando uma proposta EMI gerada pelo sistema com a PTC real aprovada pela
  # Papyrus: nem Charlene nem Ricardo apareciam. Causa: study_type sem NENHUM study_template
  # cadastrado (RAP, Relatório Técnico, PEA, EMI, hoje — ver CLAUDE.md seção 11.1) fazia
  # build_with_ai_suggested_team! retornar cedo (templates.empty?), sem chamar
  # ensure_always_included_lines! nunca.
  test "build_with_ai_suggested_team! includes always_included professionals even when the study_type has no study_templates at all" do
    conversation = Conversation.create!(user: users(:one), client_name: "Sem Templates", status: "reviewing", study_type: study_types(:rap))
    proposal = conversation.create_proposal!(status: "draft")

    pricing = proposal.build_with_ai_suggested_team!

    assert pricing.proposal_professionals.exists?(professional: professionals(:diretora))
  end

  test "build_from_template! includes always_included professionals even when the study_type has no study_templates at all" do
    conversation = Conversation.create!(user: users(:one), client_name: "Sem Templates", status: "reviewing", study_type: study_types(:rap))
    proposal = conversation.create_proposal!(status: "draft")

    pricing = proposal.build_from_template!

    line = pricing.proposal_professionals.find_by(professional: professionals(:diretora))
    assert line.present?
    assert_equal "Diretora de Negócios", line.deliverable_name # role do professional, sem template pra saber o entregável
    assert_equal 0, line.hours_office
    assert_equal 0, line.hours_field
  end

  test "build_from_template! includes an always_included professional even when their own template defaults to zero hours" do
    proposal = @conversation.create_proposal!(status: "draft")

    pricing = proposal.build_from_template!

    diretora_line = pricing.proposal_professionals.find_by(professional: professionals(:diretora))
    assert diretora_line.present?
  end

  test "build_with_ai_suggested_team! falls back to the template when the AI reply is not valid JSON" do
    proposal = @conversation.create_proposal!(status: "draft")

    pricing = stub_ai_complete("isso não é json") { proposal.build_with_ai_suggested_team! }

    # 3 templates no menu (coordenação, fauna/flora, direção da diretora fixa).
    assert_equal 3, pricing.proposal_professionals.count
  end

  test "build_with_ai_suggested_team! strips markdown fences before parsing" do
    proposal = @conversation.create_proposal!(status: "draft")
    ai_response = "```json\n" + { linhas: [], documentos_separados: false }.to_json + "\n```"

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    # Nenhuma linha válida vinda da IA (vazio) cai no fallback do template (3 templates no menu).
    assert_equal 3, pricing.proposal_professionals.count
  end

  test "build_with_ai_suggested_team! falls back to the template when the AI call itself raises" do
    proposal = @conversation.create_proposal!(status: "draft")

    pricing = stub_ai_error { proposal.build_with_ai_suggested_team! }

    assert_equal 3, pricing.proposal_professionals.count
  end

  test "build_with_ai_suggested_schedule! persists servico items in the order suggested, grouped by phase" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_from_template!
    ai_response = {
      cronograma_servico: [
        { fase: "Mobilização", atividade: "Assinatura do Contrato", periodo_inicio: 1, duracao: 1, marco: false },
        { fase: "Mobilização", atividade: "Campanhas de Campo", periodo_inicio: 2, duracao: 3, marco: false },
        { fase: "Emissão", atividade: "Emissão da LP", periodo_inicio: 6, duracao: 1, marco: true }
      ],
      cronograma_implantacao: []
    }.to_json

    stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_schedule! }

    items = proposal.project_pricing.schedule_items.for_type("servico").to_a
    assert_equal 3, items.size
    assert_equal %w[Mobilização Mobilização Emissão], items.map(&:phase_name)
    assert_equal 6, items.last.start_period
    assert items.last.milestone
    assert_not items.first.milestone
    assert_empty proposal.project_pricing.schedule_items.for_type("implantacao")
  end

  test "build_with_ai_suggested_schedule! only fills cronograma_implantacao when the AI provides it" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_from_template!
    ai_response = {
      cronograma_servico: [],
      cronograma_implantacao: [
        { fase: "Construção", atividade: "Obras civis", periodo_inicio: 1, duracao: 12, marco: false }
      ]
    }.to_json

    stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_schedule! }

    items = proposal.project_pricing.schedule_items.for_type("implantacao").to_a
    assert_equal 1, items.size
    assert_equal 12, items.first.duration_periods
  end

  test "build_with_ai_suggested_schedule! skips an incomplete line instead of raising" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_from_template!
    ai_response = {
      cronograma_servico: [
        { fase: "", atividade: "Sem fase", periodo_inicio: 1, duracao: 1, marco: false },
        { fase: "Mobilização", atividade: "Período inválido", periodo_inicio: 0, duracao: 1, marco: false },
        { fase: "Mobilização", atividade: "Válida", periodo_inicio: 1, duracao: 1, marco: false }
      ]
    }.to_json

    stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_schedule! }

    assert_equal [ "Válida" ], proposal.project_pricing.schedule_items.for_type("servico").map(&:activity_name)
  end

  test "build_with_ai_suggested_schedule! leaves the proposal without a schedule when the AI reply is not valid JSON, without raising" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_from_template!

    stub_ai_complete("isso não é json") { proposal.build_with_ai_suggested_schedule! }

    assert_empty proposal.project_pricing.schedule_items
  end

  test "build_with_ai_suggested_schedule! does not raise and leaves no schedule when the AI call itself errors out" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_from_template!

    stub_ai_error { proposal.build_with_ai_suggested_schedule! }

    assert_empty proposal.project_pricing.schedule_items
  end

  test "build_with_ai_suggested_schedule! never sets the start dates — those are always the consultant's" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_from_template!
    ai_response = { cronograma_servico: [ { fase: "Mobilização", atividade: "X", periodo_inicio: 1, duracao: 1, marco: false } ] }.to_json

    stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_schedule! }

    assert_nil proposal.project_pricing.schedule_papyrus_start_date
    assert_nil proposal.project_pricing.schedule_empreendimento_start_date
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

  # O modelo da Papyrus (revisão de 2026-08) deixou de trazer o quadro de preço aberto por linha:
  # o que o cliente lê é o total na frase de abertura da seção 10.
  test "docx_total_price comes from the pricing engine, formatted for the document" do
    proposal = proposals(:priced_proposal)

    assert_equal number_to_currency(proposal.project_pricing.total_value, unit: "R$", separator: ",", delimiter: "."),
                 proposal.docx_total_price
  end

  test "docx_payment_schedule_rows carries the milestone, the amount in R$ and the date" do
    proposal = proposals(:priced_proposal)
    pricing = proposal.project_pricing
    pricing.payment_dates = [ "2026-03-25" ]
    pricing.save!

    rows = proposal.reload.docx_payment_schedule_rows

    assert_equal 4, rows.size
    assert_equal [ "Assinatura do contrato", "13.473,00", "25/03/2026" ], rows.first
  end

  # Parcela sem data combinada não pode virar data inventada nem quebrar a geração.
  test "docx_payment_schedule_rows leaves the date blank when the consultant hasn't set one" do
    rows = proposals(:priced_proposal).docx_payment_schedule_rows

    assert_equal "", rows.first.last
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

  test "docx_numero_proposta pads the record id with leading zeros up to 3 digits (passo a passo interno, item 1)" do
    proposal = proposals(:priced_proposal)
    year = proposal.created_at.strftime("%y")
    proposal.define_singleton_method(:id) { 7 }

    assert_equal "PTC#{year}007", proposal.docx_numero_proposta("combined")
  end

  test "docx_filename follows the real Papyrus naming pattern with an escopo segment (tipo de estudo + município/UF)" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)

    expected = "#{proposal.docx_numero_proposta('tecnica')}_#{proposal.conversation.client_name}_RAP_Vitória da Conquista_BA_Rev.00.docx"
    assert_equal expected, proposal.docx_filename("tecnica", municipio: "Vitória da Conquista", estado: "ba")
  end

  test "docx_filename falls back to just the tipo de estudo when município/UF aren't known yet" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)

    expected = "#{proposal.docx_numero_proposta('combined')}_#{proposal.conversation.client_name}_RAP_Rev.00.docx"
    assert_equal expected, proposal.docx_filename("combined")
  end

  # O consultor dita o nome no chat quando a pasta na rede e o controle de propostas já existem
  # com aquele nome (itens 1 e 2 do passo a passo interno).
  test "docx_filename uses the name the consultant dictated, adding only the revision" do
    proposal = proposals(:priced_proposal)
    proposal.update!(docx_filename_override: "PTC26002_PMM_LU_Simões Filho_BA", version: 1)

    assert_equal "PTC26002_PMM_LU_Simões Filho_BA_Rev.00.docx", proposal.docx_filename("combined")
  end

  test "docx_filename respects a revision the consultant wrote himself instead of adding another" do
    proposal = proposals(:priced_proposal)
    proposal.update!(docx_filename_override: "PTC26002_PMM_Rev.03", version: 5)

    assert_equal "PTC26002_PMM_Rev.03.docx", proposal.docx_filename("combined")
  end

  # Técnica e comercial não podem sair com o mesmo nome; trocar PTC/PT/PC é a convenção da Papyrus.
  test "docx_filename swaps the proposal-number prefix to tell técnica from comercial" do
    proposal = proposals(:priced_proposal)
    proposal.update!(docx_filename_override: "PTC26002_PMM_LU", version: 1)

    assert_equal "PT26002_PMM_LU_Rev.00.docx", proposal.docx_filename("tecnica")
    assert_equal "PC26002_PMM_LU_Rev.00.docx", proposal.docx_filename("comercial")
  end

  test "docx_filename falls back to a suffix when the dictated name has no proposal number" do
    proposal = proposals(:priced_proposal)
    proposal.update!(docx_filename_override: "Proposta PMM galpões", version: 1)

    assert_equal "Proposta PMM galpões_Tecnica_Rev.00.docx", proposal.docx_filename("tecnica")
    assert_equal "Proposta PMM galpões_Rev.00.docx", proposal.docx_filename("combined")
  end

  test "docx_filename drops a .docx the consultant typed and keeps the name sanitized" do
    proposal = proposals(:priced_proposal)
    proposal.update!(docx_filename_override: "PTC26002_PMM/LU.docx", version: 1)

    assert_equal "PTC26002_PMM-LU_Rev.00.docx", proposal.docx_filename("combined")
  end

  test "docx_filename sanitizes filesystem-unsafe characters from client name and município" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)
    proposal.conversation.update!(client_name: "Cliente/Teste: \"Especial\"")

    filename = proposal.docx_filename("combined", municipio: "Município/Teste", estado: "ba")

    assert_includes filename, "Cliente-Teste- -Especial-"
    assert_includes filename, "Município-Teste"
    assert_includes filename, "_BA_"
  end
end
