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

  test "build_base_team! só coloca a equipe fixa (always_included), com o cargo como entregável e 0h" do
    proposal = @conversation.create_proposal!(status: "draft")

    pricing = proposal.build_base_team!

    assert_equal [ professionals(:diretora) ], pricing.proposal_professionals.map(&:professional)
    line = pricing.proposal_professionals.sole
    assert_equal "Diretora de Negócios", line.deliverable_name
    assert_equal 0, line.man_hours
    assert_equal 0, line.field_days
  end

  # Sem study_templates (2026-09): a IA monta a equipe direto do cadastro de profissionais, em
  # qualquer tipo de estudo — escolhe quem entra, o entregável e o esforço (HH + diárias).
  test "build_with_ai_suggested_team! monta a equipe a partir do cadastro de profissionais" do
    proposal = @conversation.create_proposal!(status: "draft")
    ai_response = {
      linhas: [
        { professional_id: professionals(:coordenador).id, deliverable_name: "Coordenação geral", man_hours: 60, field_days: 0 },
        { professional_id: professionals(:biologa).id, deliverable_name: "Diagnóstico de Fauna e Flora", man_hours: 40, field_days: 6 }
      ],
      documentos_separados: false
    }.to_json

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    biologa = pricing.proposal_professionals.find_by(professional: professionals(:biologa))
    assert_equal "Diagnóstico de Fauna e Flora", biologa.deliverable_name
    assert_equal 40, biologa.man_hours
    assert_equal 6, biologa.field_days
    assert_equal 60, pricing.proposal_professionals.find_by(professional: professionals(:coordenador)).man_hours
    # + a diretora (always_included), que entra sozinha mesmo sem linha da IA.
    assert_equal 3, pricing.proposal_professionals.count
    assert pricing.total_value.positive?
    assert_equal "combined", proposal.reload.document_split
  end

  test "build_with_ai_suggested_team! grava a etapa de cada linha e liga o preço discriminado quando o ET pede" do
    proposal = @conversation.create_proposal!(status: "draft")
    ai_response = {
      linhas: [ { professional_id: professionals(:biologa).id, deliverable_name: "Diagnóstico de Fauna", etapa: " Campanhas de campo ", man_hours: 40, field_days: 6 } ],
      preco_discriminado: true, documentos_separados: false
    }.to_json

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    assert_equal "Campanhas de campo", pricing.proposal_professionals.find_by(professional: professionals(:biologa)).stage
    assert pricing.reload.price_breakdown?
  end

  test "build_with_ai_suggested_team! lista a equipe fixa e o quadro completo no prompt" do
    proposal = @conversation.create_proposal!(status: "draft")
    prompt = nil
    original = @conversation.method(:ask_internally)
    @conversation.define_singleton_method(:ask_internally) { |text, **opts| prompt = text; original.call(text, **opts) }
    proposal.conversation = @conversation

    stub_ai_complete({ linhas: [], documentos_separados: false }.to_json) { proposal.build_with_ai_suggested_team! }

    assert_includes prompt, "EQUIPE FIXA"
    assert_includes prompt, professionals(:diretora).name
    assert_includes prompt, professionals(:biologa).name
    assert_includes prompt, professionals(:biologa).specialties
    assert_not_includes prompt, professionals(:inativo).name
    assert_includes prompt, "EIA-RIMA"
  end

  # Avaliação do RAG (2026-09-27): equipes de projetos anteriores parecidos entram no prompt de
  # equipe sozinhas, sem depender da IA chamar ferramenta.
  test "prompt de equipe traz as equipes de projetos anteriores parecidos" do
    proposal = @conversation.create_proposal!(status: "draft")
    precedent = JobPrecedent.new(job_number: "26098", client_name: "Newave", year: 2026, service: "Licenciamento de BESS",
      duration: "24 meses", team: [ { "funcao" => "Meio Físico", "horas_homem" => 80, "diarias" => 5 } ])
    match = Rag::PrecedentFinder::Match.new(precedent: precedent, similarity: 0.8)
    finder = Object.new.tap { |f| f.define_singleton_method(:call) { |*, **| [ match ] } }

    prompt = stub_class_method(Rag::PrecedentFinder, :new, ->(*) { finder }) { proposal.send(:team_suggestion_prompt) }

    assert_includes prompt, "EQUIPES DE PROJETOS ANTERIORES PARECIDOS"
    assert_includes prompt, "acervo Papyrus: projeto 26098"
    assert_includes prompt, "Meio Físico (80 HH, 5 diárias)"
  end

  test "prompt de equipe segue normal quando a busca de precedentes falha" do
    proposal = @conversation.create_proposal!(status: "draft")

    prompt = stub_class_method(Rag::PrecedentFinder, :new, ->(*) { raise "Bedrock fora" }) { proposal.send(:team_suggestion_prompt) }

    assert_includes prompt, "EQUIPE FIXA"
    assert_not_includes prompt, "PROJETOS ANTERIORES"
  end

  # A linha fora do cadastro continua fora da precificação, mas para de sumir em silêncio: ou
  # falta cadastro, ou a IA inventou, e as duas coisas são informação para o consultor.
  test "build_with_ai_suggested_team! descarta e sinaliza profissional inexistente ou inativo" do
    proposal = @conversation.create_proposal!(status: "draft")
    ai_response = {
      linhas: [
        { professional_id: 999_999, deliverable_name: "Arqueólogo sênior", man_hours: 100, field_days: 10 },
        { professional_id: professionals(:inativo).id, deliverable_name: "Meio Físico", man_hours: 10, field_days: 0 }
      ],
      documentos_separados: false
    }.to_json

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    assert_not pricing.proposal_professionals.exists?(professional: professionals(:inativo))
    flags = @conversation.project_findings.where(nature: "sugestao").pluck(:value)
    assert_equal 2, flags.size
    assert flags.any? { |value| value.include?("Arqueólogo sênior") && value.include?("fora do cadastro") }
    assert_equal "sistema", @conversation.project_findings.find_by(nature: "sugestao").source_kind
  end

  test "build_with_ai_suggested_team! ignora linha duplicada (mesmo profissional e entregável)" do
    proposal = @conversation.create_proposal!(status: "draft")
    line = { professional_id: professionals(:biologa).id, deliverable_name: "Fauna", man_hours: 10, field_days: 1 }
    ai_response = { linhas: [ line, line.merge(deliverable_name: " fauna ") ], documentos_separados: false }.to_json

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    assert_equal 1, pricing.proposal_professionals.where(professional: professionals(:biologa)).count
  end

  test "build_with_ai_suggested_team! sets document_split to separated when the AI flags it" do
    proposal = @conversation.create_proposal!(status: "draft")

    stub_ai_complete({ linhas: [], documentos_separados: true }.to_json) { proposal.build_with_ai_suggested_team! }

    assert_equal "separated", proposal.reload.document_split
  end

  test "build_with_ai_suggested_team! inclui a equipe fixa mesmo quando a IA não sugere linha pra ela" do
    proposal = @conversation.create_proposal!(status: "draft")
    ai_response = {
      linhas: [ { professional_id: professionals(:coordenador).id, deliverable_name: "Coordenação geral", man_hours: 60, field_days: 0 } ],
      documentos_separados: false
    }.to_json

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    diretora_line = pricing.proposal_professionals.find_by(professional: professionals(:diretora))
    assert_equal 0, diretora_line.man_hours
    assert_equal 0, diretora_line.field_days
  end

  test "build_with_ai_suggested_team! usa o esforço e o entregável que a IA sugeriu para a equipe fixa" do
    proposal = @conversation.create_proposal!(status: "draft")
    ai_response = {
      linhas: [ { professional_id: professionals(:diretora).id, deliverable_name: "Direção de Negócios", man_hours: 15, field_days: 1 } ],
      documentos_separados: false
    }.to_json

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    line = pricing.proposal_professionals.sole
    assert_equal "Direção de Negócios", line.deliverable_name
    assert_equal 15, line.man_hours
    assert_equal 1, line.field_days
  end

  test "build_with_ai_suggested_team! funciona sem nenhum tipo de estudo (acompanhamento)" do
    conversation = Conversation.create!(user: users(:one), client_name: "Acompanhamento", status: "reviewing")
    proposal = conversation.create_proposal!(status: "draft")
    ai_response = {
      linhas: [ { professional_id: professionals(:biologa).id, deliverable_name: "Monitoramento de fauna", man_hours: 20, field_days: 4 } ],
      documentos_separados: false
    }.to_json

    pricing = stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_team! }

    assert pricing.proposal_professionals.exists?(professional: professionals(:biologa))
    assert pricing.proposal_professionals.exists?(professional: professionals(:diretora))
  end

  test "build_with_ai_suggested_team! cai na equipe base quando a resposta não é JSON" do
    proposal = @conversation.create_proposal!(status: "draft")

    pricing = stub_ai_complete("isso não é json") { proposal.build_with_ai_suggested_team! }

    assert_equal [ professionals(:diretora) ], pricing.proposal_professionals.map(&:professional)
  end

  test "build_with_ai_suggested_team! cai na equipe base quando a chamada de IA levanta" do
    proposal = @conversation.create_proposal!(status: "draft")

    pricing = stub_ai_error { proposal.build_with_ai_suggested_team! }

    assert_equal [ professionals(:diretora) ], pricing.proposal_professionals.map(&:professional)
  end

  # Achado em produção: GenerateProposalDocumentTool sempre chama ensure_proposal!(ai_suggestions:
  # false) — gerar a proposta direto pelo chat deixava a equipe só com Diretoria/Coordenação a 0h.
  # suggest_team_if_missing! (via SuggestTeamJob, em background) completa a equipe.
  test "suggest_team_if_missing! completa a equipe e reaproveita a linha-placeholder da equipe fixa" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!
    ai_response = {
      linhas: [
        { professional_id: professionals(:biologa).id, deliverable_name: "Diagnóstico de Fauna e Flora", man_hours: 40, field_days: 6 },
        { professional_id: professionals(:diretora).id, deliverable_name: "Direção de Negócios", man_hours: 8, field_days: 0 }
      ],
      documentos_separados: true
    }.to_json

    stub_ai_complete(ai_response) { proposal.suggest_team_if_missing! }

    pricing = proposal.project_pricing.reload
    assert_equal 40, pricing.proposal_professionals.find_by(professional: professionals(:biologa)).man_hours
    diretora = pricing.proposal_professionals.where(professional: professionals(:diretora))
    assert_equal 1, diretora.count, "substitui o placeholder em vez de duplicar a diretora"
    assert_equal [ "Direção de Negócios", 8 ], [ diretora.sole.deliverable_name, diretora.sole.man_hours ]
    assert_equal "separated", proposal.reload.document_split
  end

  test "suggest_team_if_missing! não faz nada quando já existe linha além da equipe fixa" do
    proposal = @conversation.create_proposal!(status: "draft")
    pricing = proposal.build_base_team!
    pricing.proposal_professionals.create!(professional: professionals(:biologa), deliverable_name: "Ajustado à mão", man_hours: 10, field_days: 0)

    assert_no_ai_calls { proposal.suggest_team_if_missing! }
  end

  test "suggest_team_if_missing! não faz nada quando o consultor já deu horas à equipe fixa" do
    proposal = @conversation.create_proposal!(status: "draft")
    pricing = proposal.build_base_team!
    pricing.proposal_professionals.sole.update!(man_hours: 5)

    assert_no_ai_calls { proposal.suggest_team_if_missing! }
  end

  test "suggest_team_if_missing! leaves the team untouched when the AI reply isn't valid JSON" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!

    stub_ai_complete("isso não é json") { proposal.suggest_team_if_missing! }

    assert_equal [ professionals(:diretora) ], proposal.project_pricing.reload.proposal_professionals.map(&:professional)
  end

  test "build_with_ai_suggested_schedule! persists servico items in the order suggested, grouped by phase" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!
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
    proposal.build_base_team!
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
    proposal.build_base_team!
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
    proposal.build_base_team!

    stub_ai_complete("isso não é json") { proposal.build_with_ai_suggested_schedule! }

    assert_empty proposal.project_pricing.schedule_items
  end

  test "build_with_ai_suggested_schedule! does not raise and leaves no schedule when the AI call itself errors out" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!

    stub_ai_error { proposal.build_with_ai_suggested_schedule! }

    assert_empty proposal.project_pricing.schedule_items
  end

  test "build_with_ai_suggested_schedule! never sets the start dates — those are always the consultant's" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!
    ai_response = { cronograma_servico: [ { fase: "Mobilização", atividade: "X", periodo_inicio: 1, duracao: 1, marco: false } ] }.to_json

    stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_schedule! }

    assert_nil proposal.project_pricing.schedule_papyrus_start_date
    assert_nil proposal.project_pricing.schedule_empreendimento_start_date
  end

  test "build_with_ai_suggested_schedule! stores the elected infographic marcos, ordered and capped at 6" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!
    ai_response = {
      cronograma_servico: [ { fase: "Mobilização", atividade: "X", periodo_inicio: 1, duracao: 1, marco: false } ],
      marcos_infografico: [
        { nome: "Emissão da LP", periodo: 20 },
        { nome: "Assinatura do contrato", periodo: 1 },
        { nome: "Protocolo no órgão", periodo: 8 },
        { nome: "", periodo: 5 },
        { nome: "Sem período", periodo: 0 },
        { nome: "Campanha de campo", periodo: 4 },
        { nome: "Reunião de partida", periodo: 2 },
        { nome: "Entrega final", periodo: 24 },
        { nome: "Excedente", periodo: 26 }
      ]
    }.to_json

    stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_schedule! }

    key_points = proposal.project_pricing.reload.schedule_key_points
    assert_equal 6, key_points.size
    assert_equal [ 1, 2, 4, 8, 20, 24 ], key_points.map { |m| m["periodo"] }
    assert_equal "Assinatura do contrato", key_points.first["nome"]
    assert_not_includes key_points.map { |m| m["nome"] }, ""
    assert_not_includes key_points.map { |m| m["nome"] }, "Sem período"
  end

  test "build_with_ai_suggested_schedule! leaves schedule_key_points empty when the AI omits marcos_infografico" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!
    ai_response = { cronograma_servico: [ { fase: "Mobilização", atividade: "X", periodo_inicio: 1, duracao: 1, marco: false } ] }.to_json

    stub_ai_complete(ai_response) { proposal.build_with_ai_suggested_schedule! }

    assert_empty proposal.project_pricing.reload.schedule_key_points
  end

  # Achado em produção (conversa 44): o consultor pediu pra encurtar um cronograma de 12 pra 6
  # meses, e a IA só tinha generate_proposal_document pra "atualizar" — mas essa ferramenta só LÊ
  # schedule_items, nunca escreve. regenerate_schedule! é o único caminho que de fato reconstrói.
  test "regenerate_schedule! replaces the existing schedule instead of appending to it" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!
    pricing = proposal.project_pricing
    pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Antigo", activity_name: "Fase de 12 meses",
      start_period: 1, duration_periods: 52, position: 0)
    ai_response = {
      cronograma_servico: [
        { fase: "Novo", atividade: "Fase de 6 meses", periodo_inicio: 1, duracao: 26, marco: false }
      ],
      cronograma_implantacao: []
    }.to_json

    stub_ai_complete(ai_response) { proposal.regenerate_schedule! }

    items = pricing.schedule_items.for_type("servico").to_a
    assert_equal [ "Fase de 6 meses" ], items.map(&:activity_name)
    assert_equal 26, items.first.duration_periods
  end

  test "regenerate_schedule! also replaces schedule_key_points, not just the items" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!
    pricing = proposal.project_pricing
    pricing.update!(schedule_key_points: [ { "nome" => "Marco antigo", "periodo" => 20 } ])
    pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Antigo", activity_name: "Fase de 12 meses",
      start_period: 1, duration_periods: 52, position: 0)
    ai_response = {
      cronograma_servico: [ { fase: "Novo", atividade: "Fase de 6 meses", periodo_inicio: 1, duracao: 26, marco: false } ],
      marcos_infografico: [ { nome: "Marco novo", periodo: 1 } ]
    }.to_json

    stub_ai_complete(ai_response) { proposal.regenerate_schedule! }

    key_points = pricing.reload.schedule_key_points
    assert_equal [ "Marco novo" ], key_points.map { |m| m["nome"] }
  end

  test "regenerate_schedule! leaves the previous schedule untouched when the AI reply isn't valid JSON" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!
    pricing = proposal.project_pricing
    pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Antigo", activity_name: "Fase de 12 meses",
      start_period: 1, duration_periods: 52, position: 0)

    stub_ai_complete("isso não é json") { proposal.regenerate_schedule! }

    assert_equal [ "Fase de 12 meses" ], pricing.schedule_items.for_type("servico").map(&:activity_name)
  end

  test "elect_schedule_key_points! picks the marcos from an already-built servico schedule, without touching the items" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!
    pricing = proposal.project_pricing
    pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização", activity_name: "Assinatura", start_period: 1, duration_periods: 1, position: 0)
    pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Protocolo", activity_name: "Protocolo no órgão", start_period: 8, duration_periods: 1, milestone: true, position: 1)
    ai_response = { marcos_infografico: [
      { nome: "Protocolo no órgão", periodo: 8 }, { nome: "Assinatura do contrato", periodo: 1 }
    ] }.to_json

    assert_no_difference -> { pricing.schedule_items.count } do
      stub_ai_complete(ai_response) { proposal.elect_schedule_key_points! }
    end

    assert_equal [ 1, 8 ], pricing.reload.schedule_key_points.map { |m| m["periodo"] }
  end

  test "elect_schedule_key_points! is a no-op when there is no servico schedule" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!

    stub_ai_complete({ marcos_infografico: [ { nome: "X", periodo: 1 } ] }.to_json) { proposal.elect_schedule_key_points! }

    assert_empty proposal.project_pricing.reload.schedule_key_points
  end

  test "default_schedule_key_points: seleciona deterministicamente até 6 marcos cronológicos" do
    proposal = @conversation.create_proposal!(status: "draft")
    proposal.build_base_team!
    pricing = proposal.project_pricing

    # Cria 8 itens com fases e marcos misturados
    (1..8).each do |n|
      pricing.schedule_items.create!(
        schedule_type: "servico", phase_name: "Fase #{n}", activity_name: "Atividade #{n}",
        start_period: n * 2, duration_periods: 2, milestone: (n % 2 == 0), position: n
      )
    end

    points = proposal.default_schedule_key_points
    assert_operator points.size, :<=, 6
    assert_operator points.size, :>=, 2
    assert_equal points.sort_by { |p| p["periodo"] }, points
    assert_equal 2, points.first["periodo"]
    assert_equal 16, points.last["periodo"]
  end

  test "team_rows_for_docx: uma linha por profissional, [SETOR, FUNÇÃO, PROFISSIONAL, HABILITAÇÃO], agrupada por setor" do
    proposal = proposals(:priced_proposal)
    proposal.project_pricing.proposal_professionals.create!(
      professional: professionals(:diretora), deliverable_name: "Direção de Negócios",
      man_hours: 0, field_days: 0, subtotal: 0
    )

    rows = proposal.team_rows_for_docx

    # Diretora (always_included, cargo "Diretora de Negócios") vem primeiro, no setor Diretoria;
    # coordenador e bióloga (execução) depois.
    assert_equal [ "Diretoria", "Direção de Negócios", "Diretora Fixa", "Direção — CREA 00000" ], rows.first
    coordenador_row = rows.find { |r| r[2] == "Pedro Almeida" }
    assert_equal "Execução", coordenador_row[0]
    assert_equal "Coordenação geral", coordenador_row[1] # FUNÇÃO é o entregável desta proposta, não o cargo
    assert_includes coordenador_row[3], "CREA 12345"
  end

  # O modelo da Papyrus (revisão de 2026-08) deixou de trazer o quadro de preço aberto por linha:
  # o que o cliente lê é o total na frase de abertura da seção 10.
  test "docx_total_price comes from the pricing engine, formatted for the document" do
    proposal = proposals(:priced_proposal)

    assert_equal number_to_currency(proposal.project_pricing.total_value, unit: "R$", separator: ",", delimiter: "."),
                 proposal.docx_total_price
  end

  # 2026-09-27: o quadro de desembolso voltou a trazer o valor de cada parcela, calculado pelo
  # sistema (% × total) — pedido do consultor, "o desembolso tem que ser calculado".
  test "docx_payment_schedule_rows traz marco, percentual e valor calculado de cada parcela" do
    proposal = proposals(:priced_proposal)
    proposal.project_pricing.update_columns(total_value: 10_000)

    rows = proposal.docx_payment_schedule_rows

    assert_equal 4, rows.size
    assert_equal [ "Assinatura do contrato", "30%", "3.000,00" ], rows.first
    assert_equal [ "Emissão da licença", "5%", "500,00" ], rows.last
  end

  test "docx_payment_schedule_rows formats a non-integer percentage with a comma" do
    proposal = proposals(:priced_proposal)
    proposal.project_pricing.update!(payment_schedule: [ { "label" => "Assinatura", "percentage" => 37.5 }, { "label" => "Final", "percentage" => 62.5 } ])
    proposal.project_pricing.update_columns(total_value: 1000)

    assert_equal [ "Assinatura", "37,5%", "375,00" ], proposal.docx_payment_schedule_rows.first
  end

  test "docx_price_rows: 1 linha só, com o nome do serviço e o preço total formatado" do
    proposal = proposals(:priced_proposal)

    assert_equal [ [ "1", proposal.docx_servico_label, "44.910,00" ] ], proposal.docx_price_rows
  end

  test "docx_price_rows discriminado: uma linha por etapa, calculada pelo sistema, e TOTAL no fim" do
    proposal = proposals(:priced_proposal)
    proposal_professionals(:coordenacao_line).update!(stage: "Planejamento")
    proposal_professionals(:fauna_flora_line).update!(stage: "Campanhas de campo")
    proposal.project_pricing.update!(price_breakdown: true)

    # Logística (R$ 1.650) vai toda pra etapa que tem diárias de campo.
    rows = proposal.reload.docx_price_rows
    assert_equal [ "1", "2" ], rows[0..1].map(&:first)
    assert_equal [ [ "Campanhas de campo", "29.910,00" ], [ "Planejamento", "15.000,00" ] ], rows[0..1].map { |row| row[1..] }.sort
    assert_equal [ "", "TOTAL", "44.910,00" ], rows.last
  end

  test "docx_price_rows: preço discriminado pedido mas sem 2 etapas cai no total único" do
    proposal = proposals(:priced_proposal)
    proposal.project_pricing.update!(price_breakdown: true)
    proposal_professionals(:fauna_flora_line).update!(stage: "Campanhas de campo")

    assert_not proposal.reload.price_breakdown_active?
    assert_equal 1, proposal.docx_price_rows.size
  end

  test "docx_servico_label derives from the identified ato de licenciamento, never from the AI" do
    proposal = proposals(:priced_proposal)
    proposal.conversation.project_findings.create!(field: "tipo_licenca", value: "(RLP)", nature: "fato", source_kind: "et")

    assert_equal "Renovação da Licença Prévia - RLP", proposal.docx_servico_label(fallback: "texto que a IA escreveu")
  end

  test "docx_servico_label combines more than one ato with 'e', joining the siglas with '+'" do
    proposal = proposals(:priced_proposal)
    proposal.conversation.project_findings.create!(field: "tipo_licenca", value: "(LP)", nature: "fato", source_kind: "et")
    proposal.conversation.project_findings.create!(field: "tipo_licenca", value: "(LI)", nature: "fato", source_kind: "et")

    assert_equal "Licença Prévia e Licença de Instalação - LP+LI", proposal.docx_servico_label
  end

  test "docx_servico_label falls back to the AI's descricao_servico when no ato was identified" do
    proposal = proposals(:priced_proposal)

    assert_empty proposal.license_act_acronyms
    assert_equal "elaboração de EIA/RIMA do Parque Eólico X", proposal.docx_servico_label(fallback: "elaboração de EIA/RIMA do Parque Eólico X")
  end

  test "docx_servico_label falls back to a generic label when there is no ato and no fallback text" do
    proposal = proposals(:priced_proposal)

    assert_equal "Serviço", proposal.docx_servico_label(fallback: "  ")
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

  # Achado ao vivo: uma geração que reentra/repete (mesma corrida de fundo já vista com o
  # cronograma) pode deixar um blob de generated_documents com metadata[:version] IGUAL à versão
  # atual (já incrementada) — sem o filtro `v.to_i < version`, esse blob duplicava a linha da
  # revisão atual no Sumário de Revisões.
  test "docx_revision_rows never duplicates the current row, even if a stray blob shares its version" do
    proposal = proposals(:priced_proposal)
    proposal.generated_documents.attach(
      io: StringIO.new("stray"), filename: "stray.docx", content_type: "application/octet-stream",
      metadata: { kind: "combined", version: 2, description: "Tentativa anterior" }
    )
    proposal.update!(version: 2)

    rows = proposal.docx_revision_rows(current_description: "Ajuste de escopo")

    assert_equal 1, rows.size
    assert_equal [ "01", "Ajuste de escopo", Date.current.strftime("%d/%m/%Y") ], rows.first
  end

  test "docx_revision_rows defaults a blank or repeated 'Emissão Inicial' description to a generic label, on any revision after the first" do
    proposal = proposals(:priced_proposal)
    # Rev 1 (v.to_i == 1) fica de fora da troca — "Emissão Inicial" (em branco ou não) é o rótulo
    # implícito da 1ª linha por convenção, mesma exceção que curr_desc já faz com `version <= 1`.
    proposal.generated_documents.attach(
      io: StringIO.new("v1"), filename: "v1.docx", content_type: "application/octet-stream",
      metadata: { kind: "combined", version: 1, description: "" }
    )
    proposal.generated_documents.attach(
      io: StringIO.new("v2"), filename: "v2.docx", content_type: "application/octet-stream",
      metadata: { kind: "combined", version: 2, description: "Emissão Inicial" }
    )
    proposal.update!(version: 3)

    rows = proposal.docx_revision_rows(current_description: "")

    assert_equal [ "", "Revisão solicitada pelo consultor", "Revisão solicitada pelo consultor" ],
      rows.map { |row| row[1] }
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

  # A capa do .docx mostra só o número, sem PT/PTC/PC (2026-09, pedido do consultor) — o prefixo
  # continua existindo em #docx_numero_proposta (nome de arquivo, busca, indexação no RAG), só
  # não aparece mais impresso na capa.
  test "docx_numero_capa strips the letter prefix, keeping the rest of docx_numero_proposta intact" do
    proposal = proposals(:priced_proposal)
    year = proposal.created_at.strftime("%y")

    assert_equal "#{year}#{proposal.id}", proposal.docx_numero_capa
    assert_equal "#{year}#{proposal.id}", proposal.docx_numero_capa("combined")
    assert_equal "#{year}#{proposal.id}", proposal.docx_numero_capa("tecnica")
    assert_equal "#{year}#{proposal.id}", proposal.docx_numero_capa("comercial")
  end

  # Padrão pedido pelo consultor (2026-09): número / cliente / ato de licenciamento (LP, LI, RLP,
  # LO, ASV, AMF etc.) / nome do projeto / revisão — município/UF saíram do nome de propósito.
  # Ato e nome do projeto vêm dos achados tipo_licenca/empreendimento (ProjectFinding), já
  # extraídos do ET/TR pra outros fins.
  test "docx_filename follows the padrão pedido: número / cliente / ato / nome do projeto / revisão" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)
    proposal.conversation.project_findings.create!(field: "tipo_licenca", value: "LP", source_kind: "et")
    proposal.conversation.project_findings.create!(field: "empreendimento", value: "Parque Eólico Serra Verde", source_kind: "et")

    expected = "#{proposal.docx_numero_proposta('tecnica')}_#{proposal.conversation.client_name}_LP_Parque Eólico Serra Verde_Rev.00.docx"
    assert_equal expected, proposal.docx_filename("tecnica")
  end

  test "docx_filename falls back to just número/cliente when ato/nome do projeto aren't known yet" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)

    expected = "#{proposal.docx_numero_proposta('combined')}_#{proposal.conversation.client_name}_Rev.00.docx"
    assert_equal expected, proposal.docx_filename("combined")
  end

  test "docx_filename picks the SHORTEST active finding for nome do projeto, not the most authoritative source" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)
    conversation = proposal.conversation
    # "et" vence "complementar" na ordem de autoridade (ProjectFinding::SOURCE_KINDS), mas pro
    # nome do arquivo a versão curta é que serve — mesmo vindo de fonte "menos autoritativa".
    conversation.project_findings.create!(field: "empreendimento", source_kind: "et",
      value: "Sistema de armazenamento de energia em baterias (BESS) com potência de 40,32 MW individual")
    conversation.project_findings.create!(field: "empreendimento", source_kind: "complementar", value: "BESS São Desidério")

    assert_includes proposal.docx_filename("combined"), "_BESS São Desidério_Rev."
  end

  test "docx_filename omits nome do projeto instead of truncating it, when only a long finding is available" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)
    proposal.conversation.project_findings.create!(field: "empreendimento", source_kind: "et",
      value: "Sistema de armazenamento de energia em baterias (BESS) com 604,8 MW de potência total")

    filename = proposal.docx_filename("combined")

    assert_not_includes filename, "Sistema"
    assert_equal "#{proposal.docx_numero_proposta('combined')}_#{proposal.conversation.client_name}_Rev.00.docx", filename
  end

  # Achado ao vivo (2026-09, proposta 21/conversa 35): a IA às vezes escreve o ato por extenso
  # ("Licença Prévia e Licença de Instalação") em vez da sigla — o nome do arquivo saía enorme e
  # sem sentido pra convenção da Papyrus. Normaliza pro nome completo mais comum quando não há
  # sigla nenhuma já escrita no achado.
  test "ato_licenciamento normalizes a full license name into its acronym when no sigla is present" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)
    proposal.conversation.project_findings.create!(field: "tipo_licenca", source_kind: "et",
      value: "Licença Prévia e Licença de Instalação")

    assert_includes proposal.docx_filename("combined"), "_LP+LI_Rev."
  end

  test "ato_licenciamento uses the acronym already written in the achado, without normalizing" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)
    proposal.conversation.project_findings.create!(field: "tipo_licenca", source_kind: "et", value: "Licença Prévia (LP)")

    assert_includes proposal.docx_filename("combined"), "_LP_Rev."
  end

  test "ato_licenciamento combines acronyms from more than one achado (one act per finding) with +, without repeating" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)
    conversation = proposal.conversation
    conversation.project_findings.create!(field: "tipo_licenca", source_kind: "et", value: "Licença Prévia (LP)")
    conversation.project_findings.create!(field: "tipo_licenca", source_kind: "tr", value: "Licença de Instalação (LI)")
    conversation.project_findings.create!(field: "tipo_licenca", source_kind: "consultor", value: "LP")

    assert_includes proposal.docx_filename("combined"), "_LP+LI_Rev."
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

  test "docx_filename sanitizes filesystem-unsafe characters from client name and nome do projeto" do
    proposal = proposals(:priced_proposal)
    proposal.update!(version: 1)
    proposal.conversation.update!(client_name: "Cliente/Teste: \"Especial\"")
    proposal.conversation.project_findings.create!(field: "empreendimento", value: "Projeto/Teste", source_kind: "et")

    filename = proposal.docx_filename("combined")

    assert_includes filename, "Cliente-Teste- -Especial-"
    assert_includes filename, "Projeto-Teste"
  end
end
