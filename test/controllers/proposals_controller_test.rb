require "test_helper"

class ProposalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:two)
    @conversation = conversations(:priced_conversation)
    @proposal = proposals(:priced_proposal)
  end

  test "show renders the pricing screen" do
    get conversation_proposal_path(@conversation)
    assert_response :success
  end

  # Proposta criada antes de o valor da hora-homem ser preenchido: o subtotal gravado ficava o
  # antigo até alguém clicar em "Recalcular preço". Abrir a tela já corrige.
  test "show recalcula subtotais que não batem mais com o valor atual do cadastro" do
    professionals(:coordenador).update_columns(rate_man_hour: 300) # sem callback: simula o dado já desatualizado

    get conversation_proposal_path(@conversation)

    assert_equal 18_000, proposal_professionals(:coordenacao_line).reload.subtotal
    assert_match "R$ 18.000,00", response.body
    assert_match "R$ 300,00/h", response.body
  end

  test "show não recalcula proposta aprovada" do
    @proposal.update!(status: "approved")
    professionals(:coordenador).update_columns(rate_man_hour: 300)

    get conversation_proposal_path(@conversation)

    assert_equal 15_000, proposal_professionals(:coordenacao_line).reload.subtotal
  end

  test "show avisa quem da equipe está sem valor de hora-homem/diária" do
    professionals(:biologa).update_columns(rate_man_hour: 0, rate_daily: 0)

    get conversation_proposal_path(@conversation)

    assert_match "sem valor de hora-homem/diária cadastrado", response.body
    assert_match professionals(:biologa).name, response.body
  end

  test "update salva as parcelas editadas do desembolso" do
    patch conversation_proposal_path(@conversation), params: {
      project_pricing: { bdi: "1.20", tax_multiplier: "1.25",
                         payment_schedule_items: { "0" => { label: "Assinatura", percentage: "50", date: "" },
                                                   "1" => { label: "Entrega", percentage: "50", date: "2026-12-01" } } }
    }

    assert_redirected_to conversation_proposal_path(@conversation)
    assert_equal [ "Assinatura", "Entrega" ], @proposal.project_pricing.reload.payment_schedule.map { |item| item["label"] }
  end

  test "update recusa desembolso que não soma 100% e avisa" do
    patch conversation_proposal_path(@conversation), params: {
      project_pricing: { payment_schedule_items: { "0" => { label: "Assinatura", percentage: "70", date: "" } } }
    }

    assert_match "100%", flash[:alert]
    assert_equal 4, @proposal.project_pricing.reload.payment_schedule.size
  end

  test "show mostra projetos anteriores parecidos como referência (valor histórico, equipe)" do
    precedent = JobPrecedent.create!(job_number: "26098", client_name: "Newave", year: 2026, service: "Licenciamento de BESS",
      total_value: 185_000, team: [ { "funcao" => "Meio Físico", "horas_homem" => 80 } ], status: "ok")
    match = Rag::PrecedentFinder::Match.new(precedent: precedent, similarity: 0.8)
    finder = Object.new.tap { |f| f.define_singleton_method(:call) { |*, **| [ match ] } }

    stub_class_method(Rag::PrecedentFinder, :new, ->(*) { finder }) { get conversation_proposal_path(@conversation) }

    assert_select "h2", text: "Projetos parecidos"
    assert_match "26098", response.body
    assert_match "R$ 185.000,00", response.body
    assert_match "referência de porte, não preço", response.body
  end

  test "show renders the new logistics fields and the recalculate button" do
    get conversation_proposal_path(@conversation)

    assert_select "input[name='project_pricing[vehicles_count]']"
    assert_select "input[name='project_pricing[meal_per_person_per_day]']"
    assert_select "input[name='project_pricing[lodging_per_person_per_night]']"
    assert_select "input[name='project_pricing[fuel_price_per_liter]']"
    assert_select "input[name='project_pricing[vehicle_consumption_km_per_liter]']"
    assert_select "input[name='project_pricing[travel_hours]']"
    assert_select "form[action='#{suggest_logistics_conversation_proposal_path(@conversation)}']"
  end

  test "show renders the long-distance warning banner when the pricing is flagged" do
    @proposal.project_pricing.update!(distance_km: ProjectPricing::LONG_DISTANCE_KM_THRESHOLD + 1)

    get conversation_proposal_path(@conversation)

    assert_match "deslocamento", response.body
  end

  test "show does not render the long-distance warning when the pricing isn't flagged" do
    get conversation_proposal_path(@conversation)

    assert_no_match "deslocamento", response.body
  end

  test "create builds an AI-suggested team and moves the conversation into pricing" do
    reviewing = conversations(:reviewing_conversation)
    sign_in_as reviewing.user
    ai_response = { linhas: [], documentos_separados: false }.to_json

    stub_ai_complete(ai_response) { post conversation_proposal_path(reviewing) }

    reviewing.reload
    assert_equal "pricing", reviewing.status
    assert reviewing.proposal.present?
    assert_redirected_to conversation_proposal_path(reviewing)
  end

  test "create refuses when the conversation is not in reviewing status" do
    post conversation_proposal_path(@conversation) # priced_conversation já está em "pricing"

    assert_redirected_to @conversation
    follow_redirect!
    assert_match "só pode ser precificada", response.body
  end

  # 2026-09: zero tipos de estudo é um estado válido (proposta de acompanhamento) — deixou de
  # bloquear "Avançar para Precificação" (CLAUDE.md seção 13). A IA monta a equipe do cadastro
  # de profissionais do mesmo jeito.
  test "create succeeds even when no study type was identified yet — proposta de acompanhamento" do
    reviewing = conversations(:reviewing_conversation)
    reviewing.study_types.clear
    sign_in_as reviewing.user
    ai_response = { linhas: [], documentos_separados: false }.to_json

    assert_difference "Proposal.count", 1 do
      stub_ai_complete(ai_response) { post conversation_proposal_path(reviewing) }
    end

    assert_redirected_to conversation_proposal_path(reviewing)
  end

  test "update recalculates pricing and marks the proposal as priced" do
    patch conversation_proposal_path(@conversation), params: {
      project_pricing: { bdi: "1.30", tax_multiplier: "1.25", distance_km: "120", logistics_days: "4",
                          rental_per_day: "160", meal_per_person_per_day: "90", fuel_total: "600" },
      proposal: { document_split: "combined" }
    }

    assert_redirected_to conversation_proposal_path(@conversation)
    @proposal.reload
    assert_equal "priced", @proposal.status
    assert_equal 1.30, @proposal.project_pricing.reload.bdi
  end

  # A data de cada parcela é decisão comercial do consultor, digitada na mesma tela do resto —
  # de lá ela vai direto para a Tela de Precificação (não mais pro Desembolso do .docx, que desde
  # 2026-09 mostra só % DO ITEM — ver Proposal#docx_payment_schedule_rows).
  test "update stores the instalment dates typed on the pricing screen" do
    patch conversation_proposal_path(@conversation), params: {
      project_pricing: { bdi: "1.20", tax_multiplier: "1.25", distance_km: "0", logistics_days: "0",
                          rental_per_day: "0", meal_per_person_per_day: "0", fuel_total: "0",
                          payment_dates: [ "2026-03-25", "", "2026-05-25", "" ] },
      proposal: { document_split: "combined" }
    }

    schedule = @proposal.project_pricing.reload.payment_schedule
    assert_equal "2026-03-25", schedule[0]["date"]
    assert_nil schedule[1]["date"]
    assert_equal "2026-05-25", schedule[2]["date"]
  end

  test "update rejects invalid pricing params and keeps the proposal editable" do
    patch conversation_proposal_path(@conversation), params: {
      project_pricing: { bdi: "0", tax_multiplier: "1.25", distance_km: "1", logistics_days: "1",
                          rental_per_day: "1", meal_per_person_per_day: "1", fuel_total: "1" },
      proposal: { document_split: "combined" }
    }

    assert_redirected_to conversation_proposal_path(@conversation)
    assert_not_equal "0.0", @proposal.reload.project_pricing.bdi.to_s
  end

  test "update is blocked once the proposal is approved" do
    @proposal.update!(status: "approved")

    patch conversation_proposal_path(@conversation), params: {
      project_pricing: { bdi: "2.0", tax_multiplier: "1.25", distance_km: "1", logistics_days: "1",
                          rental_per_day: "1", meal_per_person_per_day: "1", fuel_total: "1" },
      proposal: { document_split: "combined" }
    }

    follow_redirect!
    assert_match "já foi aprovada", response.body
  end

  test "suggest_logistics recalculates distance/fuel and shows a notice" do
    @proposal.conversation.create_geospatial_result!(geometry_type: "polygon", centroid: KmzGeometryExtractor::FACTORY.point(-39.5, -14.0))
    fake_result = Logistics::MapboxDirections::Result.new(distance_km: 250.0, duration_hours: 4.0)
    fake_directions = Object.new.tap { |o| o.define_singleton_method(:fetch) { fake_result } }

    stub_class_method(Logistics::MapboxDirections, :new, ->(*) { fake_directions }) do
      post suggest_logistics_conversation_proposal_path(@conversation)
    end

    assert_redirected_to conversation_proposal_path(@conversation)
    follow_redirect!
    assert_match "250.0 km", response.body
    assert_equal 250.0, @proposal.project_pricing.reload.distance_km
  end

  test "suggest_logistics is blocked once the proposal is approved" do
    @proposal.update!(status: "approved")

    post suggest_logistics_conversation_proposal_path(@conversation)

    follow_redirect!
    assert_match "já foi aprovada", response.body
  end

  test "approve locks the proposal and completes the conversation" do
    post approve_conversation_proposal_path(@conversation)

    @proposal.reload
    @conversation.reload
    assert_equal "approved", @proposal.status
    assert_equal "completed", @conversation.status
  end

  test "approve refuses a second time once already approved" do
    @proposal.update!(status: "approved")

    post approve_conversation_proposal_path(@conversation)

    follow_redirect!
    assert_match "já foi aprovada", response.body
  end

  test "approve guarda data e preço aprovados" do
    post approve_conversation_proposal_path(@conversation)

    @proposal.reload
    assert @proposal.approved_at.present?
    assert_equal @proposal.project_pricing.total_value, @proposal.approved_total
  end

  # 2026-09-27: o cliente às vezes pede mudança depois do preço aprovado.
  test "reopen destrava a proposta aprovada, volta a conversa pra precificação e guarda quem/por quê" do
    post approve_conversation_proposal_path(@conversation)

    post reopen_conversation_proposal_path(@conversation), params: { reason: "Cliente pediu campanha extra" }

    @proposal.reload
    assert_equal "priced", @proposal.status
    assert_equal "pricing", @conversation.reload.status
    assert_equal users(:two), @proposal.reopened_by
    assert_equal "Cliente pediu campanha extra", @proposal.reopen_reason
    follow_redirect!
    assert_match "Precificação reaberta", response.body
    assert_match "Motivo: Cliente pediu campanha extra", response.body
    assert_select "button", text: "Salvar e recalcular"
  end

  test "reopen avisa quando o preço mudou porque o cadastro mudou depois da aprovação" do
    post approve_conversation_proposal_path(@conversation)
    professionals(:coordenador).update_columns(rate_man_hour: 300) # proposta aprovada não recalcula sozinha

    post reopen_conversation_proposal_path(@conversation)

    assert_match "preço foi recalculado de", flash[:notice]
    assert_equal 18_000, proposal_professionals(:coordenacao_line).reload.subtotal
  end

  test "reopen recusa proposta que não está aprovada" do
    post reopen_conversation_proposal_path(@conversation)

    assert_match "não está aprovada", flash[:alert]
    assert_equal "priced", @proposal.reload.status
  end

  test "depois de reaberta, dá pra aprovar de novo" do
    post approve_conversation_proposal_path(@conversation)
    post reopen_conversation_proposal_path(@conversation)

    post approve_conversation_proposal_path(@conversation)

    assert_equal "approved", @proposal.reload.status
    assert_equal "completed", @conversation.reload.status
  end

  test "add_external_cost appends a cost line and recalculates the total" do
    original_total = @proposal.project_pricing.total_value

    post add_external_cost_conversation_proposal_path(@conversation), params: { description: "ART", value: "350" }

    pricing = @proposal.project_pricing.reload
    assert_includes pricing.external_costs, { "description" => "ART", "value" => 350.0 }
    assert_equal original_total + 350, pricing.total_value
  end

  test "add_external_cost rejects a blank description or non-positive value" do
    assert_no_changes -> { @proposal.project_pricing.reload.external_costs } do
      post add_external_cost_conversation_proposal_path(@conversation), params: { description: "", value: "350" }
    end
  end

  test "remove_external_cost drops the cost at the given index and recalculates" do
    @proposal.project_pricing.update!(external_costs: [ { "description" => "ART", "value" => 350 } ])
    @proposal.project_pricing.recalculate!

    delete remove_external_cost_conversation_proposal_path(@conversation, index: 0)

    pricing = @proposal.project_pricing.reload
    assert_empty pricing.external_costs
  end

  # Serviços Terceirizados (2026-09) — mesmo armazenamento de sempre (external_costs), só com
  # `kind: "terceirizado"` pra aparecer na seção separada da Tela de Precificação.
  test "add_external_cost tags the entry as terceirizado when kind is sent" do
    post add_external_cost_conversation_proposal_path(@conversation), params: { description: "Topografia", value: "1200", kind: "terceirizado" }

    pricing = @proposal.project_pricing.reload
    assert_includes pricing.external_costs, { "description" => "Topografia", "value" => 1200.0, "kind" => "terceirizado" }
    assert_equal [ "Topografia" ], pricing.outsourced_costs.map { |cost, _index| cost["description"] }
  end

  test "add_external_cost ignores an unknown kind value instead of tagging the entry" do
    post add_external_cost_conversation_proposal_path(@conversation), params: { description: "ART", value: "350", kind: "qualquer_coisa" }

    pricing = @proposal.project_pricing.reload
    assert_includes pricing.external_costs, { "description" => "ART", "value" => 350.0 }
    assert_empty pricing.outsourced_costs
  end

  test "show renders both the external costs and the terceirizados sections" do
    @proposal.project_pricing.update!(external_costs: [
      { "description" => "ART", "value" => 350 },
      { "description" => "Topografia", "value" => 1200, "kind" => "terceirizado" }
    ])

    get conversation_proposal_path(@conversation)

    assert_select "h2", text: "Custos externos"
    assert_select "h2", text: "Serviços terceirizados"
    assert_match "ART", response.body
    assert_match "Topografia", response.body
  end
end
