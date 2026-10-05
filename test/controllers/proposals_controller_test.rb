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

    assert_equal 18_000, proposal_professionals(:coordenacao_line).reload.subtotal # com BDI × impostos
    assert_match "R$ 12.000,00", response.body # a linha mostra o custo puro: 40 HH × R$ 300
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

  test "show renders the logistics fields, the items with their field campaigns and the recalculate button" do
    get conversation_proposal_path(@conversation)

    assert_select "input[name='project_pricing[rental_4x4_per_day]']"
    assert_select "input[name='project_pricing[daily_km]']"
    assert_select "input[name$='[field_campaigns_attributes][0][people]']"
    assert_select "select[name$='[pricing_item_id]']"
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

    assert_match "deslocamento aéreo", response.body
  end

  test "show does not render the long-distance warning when the pricing isn't flagged" do
    get conversation_proposal_path(@conversation)

    assert_no_match "deslocamento aéreo", response.body
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
      project_pricing: { bdi: "1.30", tax_multiplier: "1.25", distance_km: "120", daily_km: "80",
                          rental_per_day: "160", meal_per_person_per_day: "90" },
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
      project_pricing: { bdi: "1.20", tax_multiplier: "1.25", distance_km: "0",
                          rental_per_day: "0", meal_per_person_per_day: "0",
                          payment_dates: [ "2026-03-25", "", "2026-05-25", "" ] },
      proposal: { document_split: "combined" }
    }

    schedule = @proposal.project_pricing.reload.payment_schedule
    assert_equal "2026-03-25", schedule[0]["date"]
    assert_nil schedule[1]["date"]
    assert_equal "2026-05-25", schedule[2]["date"]
  end

  # Precificação por item (2026-09-28).
  test "update edits items, field campaigns, item costs and moves a team line to another item" do
    pricing = @proposal.project_pricing
    item = pricing_items(:servico_item)
    other = pricing.pricing_items.create!(name: "Campanhas", position: 1)
    campaign = field_campaigns(:campo_servico)
    line = proposal_professionals(:fauna_flora_line)

    patch conversation_proposal_path(@conversation), params: {
      project_pricing: {
        bdi: "1.20", tax_multiplier: "1.25",
        pricing_items_attributes: {
          "0" => { id: item.id, name: "Gestão", cost_items: { "0" => { description: "ART", quantity: "2", unit_value: "300" } },
                   field_campaigns_attributes: { "0" => { id: campaign.id, people: "3", vehicle_type: "4x4" } } },
          "1" => { id: other.id, name: "Campanhas de campo" }
        },
        proposal_professionals_attributes: { "0" => { id: line.id, pricing_item_id: other.id } }
      },
      proposal: { document_split: "combined" }
    }

    assert_redirected_to conversation_proposal_path(@conversation)
    assert_equal "Gestão", item.reload.name
    assert_equal [ { "description" => "ART", "quantity" => 2.0, "unit_value" => 300.0 } ], item.costs
    assert_equal [ 3, "4x4" ], [ campaign.reload.people, campaign.vehicle_type ]
    assert_equal other, line.reload.pricing_item
    assert_equal pricing.reload.pricing_items.sum(&:total), pricing.total_value
  end

  # 2026-10: "+ Criar item" da aba Equipe — com o nome digitado, volta pro grupo dele na Equipe.
  test "add_team_item cria o item com o nome digitado e volta pra Equipe" do
    pricing = @proposal.project_pricing
    patch conversation_proposal_path(@conversation), params: { project_pricing: { bdi: "1.30" }, structure_action: "add_team_item", new_item_name: " Relatórios " }
    item = pricing.pricing_items.reload.last
    assert_equal "Relatórios", item.name
    assert_redirected_to conversation_proposal_path(@conversation, anchor: "equipe-item-#{item.id}")
  end

  test "structure buttons add and remove items, campaigns, costs and enterprises without losing the typed values" do
    pricing = @proposal.project_pricing
    base = { bdi: "1.30", tax_multiplier: "1.25" }

    patch conversation_proposal_path(@conversation), params: { project_pricing: base, structure_action: "add_item" }
    new_item = pricing.pricing_items.reload.last
    assert_equal "Novo item", new_item.name
    assert_equal 1.30, pricing.reload.bdi, "o que foi digitado é salvo junto"
    assert_redirected_to conversation_proposal_path(@conversation, anchor: "item-#{new_item.id}")

    patch conversation_proposal_path(@conversation), params: { project_pricing: base, structure_action: "add_campaign:#{new_item.id}" }
    patch conversation_proposal_path(@conversation), params: { project_pricing: base, structure_action: "add_cost:#{new_item.id}" }
    patch conversation_proposal_path(@conversation), params: { project_pricing: base, structure_action: "add_enterprise" }
    assert_equal 1, new_item.field_campaigns.count
    assert_equal 1, new_item.reload.costs.size
    assert_equal 1, pricing.pricing_enterprises.count

    line = proposal_professionals(:coordenacao_line)
    line.update!(pricing_item: new_item)
    patch conversation_proposal_path(@conversation), params: { project_pricing: base, structure_action: "remove_item:#{new_item.id}" }
    assert_not PricingItem.exists?(new_item.id)
    assert_equal pricing_items(:servico_item), line.reload.pricing_item, "a equipe do item removido vai pro primeiro"

    patch conversation_proposal_path(@conversation), params: { project_pricing: base, structure_action: "remove_item:#{pricing_items(:servico_item).id}" }
    assert PricingItem.exists?(pricing_items(:servico_item).id), "o último item nunca sai"
  end

  # Hospedagem por campo (2026-09-29): local do campo digitado, busca na Stay22 e escolha — tudo
  # pelos botões structure_action, sem form aninhado.
  test "campaign location, lodging search and choice through the pricing form" do
    create_municipality(name: "Remanso", uf: "BA", lon: -42.2, lat: -9.7)
    campaign = field_campaigns(:campo_servico)
    item = pricing_items(:servico_item)
    fake_stay22 = Object.new
    def fake_stay22.search(**)
      [ Lodging::Stay22Client::Option.new(id: "h1", name: "Pousada do Rio", kind: "Hotel", city: "Pilão Arcado",
          price_per_night: 150.to_d, url: "https://example.com/h1", lat: -9.55, lng: -42.1) ]
    end
    campaign_params = ->(extra = {}) {
      { bdi: "1.20", tax_multiplier: "1.25",
        pricing_items_attributes: { "0" => { id: item.id, field_campaigns_attributes: { "0" => { id: campaign.id }.merge(extra) } } } }
    }

    stub_class_method(Lodging::Stay22Client, :new, ->(*) { fake_stay22 }) do
      without_mapbox_directions do
        patch conversation_proposal_path(@conversation), params: {
          project_pricing: campaign_params.call(municipality_query: "Remanso/BA"), structure_action: "search_lodging:#{campaign.id}"
        }
      end
    end
    assert_redirected_to conversation_proposal_path(@conversation, anchor: "campo-#{campaign.id}")
    assert_equal "Remanso/BA", campaign.reload.ibge_municipality.label
    assert_equal [ "Pousada do Rio" ], campaign.lodging_options.map { |o| o["name"] }

    get conversation_proposal_path(@conversation)
    assert_select "button[value='choose_lodging:#{campaign.id}:h1']", text: "Escolher"

    without_mapbox_directions do
      patch conversation_proposal_path(@conversation), params: {
        project_pricing: campaign_params.call, structure_action: "choose_lodging:#{campaign.id}:h1"
      }
    end
    campaign.reload
    assert_equal [ "hotel", 150 ], [ campaign.lodging_mode, campaign.lodging_price_per_night ]
    assert campaign.commute_km.positive?
    assert_equal @proposal.project_pricing.reload.pricing_items.sum(&:total), @proposal.project_pricing.total_value
  end

  test "an unknown campaign municipality is rejected with a message" do
    campaign = field_campaigns(:campo_servico)
    patch conversation_proposal_path(@conversation), params: { project_pricing: { bdi: "1.20",
      pricing_items_attributes: { "0" => { id: pricing_items(:servico_item).id,
        field_campaigns_attributes: { "0" => { id: campaign.id, municipality_query: "Lugar Nenhum/ZZ" } } } } } }

    assert_match(/não encontrado/, flash[:alert])
    assert_nil campaign.reload.ibge_municipality
  end

  test "update rejects invalid pricing params and keeps the proposal editable" do
    patch conversation_proposal_path(@conversation), params: {
      project_pricing: { bdi: "0", tax_multiplier: "1.25", distance_km: "1",
                          rental_per_day: "1", meal_per_person_per_day: "1" },
      proposal: { document_split: "combined" }
    }

    assert_redirected_to conversation_proposal_path(@conversation)
    assert_not_equal "0.0", @proposal.reload.project_pricing.bdi.to_s
  end

  test "update is blocked once the proposal is approved" do
    @proposal.update!(status: "approved")

    patch conversation_proposal_path(@conversation), params: {
      project_pricing: { bdi: "2.0", tax_multiplier: "1.25", distance_km: "1",
                          rental_per_day: "1", meal_per_person_per_day: "1" },
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

  # 2026-09-30: linhas da mesma pessoa juntas e Diretoria com "custo no BDI". 2026-10: equipe agrupada
  # por item, com o custo do item no cabeçalho do grupo.
  test "equipe agrupa por item, mantém juntas as linhas da mesma pessoa e mostra quem tem custo no BDI" do
    pricing = @conversation.proposal.project_pricing
    biologa = professionals(:biologa)
    diretora = professionals(:diretora)
    diretora.update!(cost_in_bdi: true)
    pricing.proposal_professionals.create!(professional: diretora, deliverable_name: "Direção", pricing_item: pricing.default_item)
    pricing.proposal_professionals.create!(professional: biologa, deliverable_name: "Relatório final", pricing_item: pricing.default_item, man_hours: 5)

    get conversation_proposal_path(@conversation)

    rows = css_select("tr[data-pricing-preview-target='line']")
    names = rows.map { |row| row.text.squish }
    biologa_rows = names.each_index.select { |i| names[i].include?(biologa.name.split.first) }
    assert_equal 2, biologa_rows.size
    assert_equal 1, biologa_rows.last - biologa_rows.first, "as duas linhas da bióloga ficam juntas"
    assert_select "tr[data-pricing-preview-target='line']", text: /custo no BDI/

    second = pricing.pricing_items.create!(name: "Relatórios", position: 9)
    pricing.proposal_professionals.create!(professional: biologa, deliverable_name: "Relatório do item 2", pricing_item: second, man_hours: 10)
    get conversation_proposal_path(@conversation)
    assert_select "[data-item-team-total='#{second.id}']", text: ActiveSupport::NumberHelper.number_to_currency(10 * biologa.rate_man_hour, unit: "R$", separator: ",", delimiter: ".")
    group = css_select("tbody").find { |tbody| tbody.text.squish.start_with?("Relatórios ") }
    assert group, "o item 2 tem cabeçalho próprio"
    assert group.at_css("input[value='Relatório do item 2']"), "a linha do item 2 fica no grupo dele"
  end

  # 2026-09-30: precificação espelhando a lista de preços do cliente.
  test "Reorganizar pela planilha do cliente enfileira o job; item espelhado mostra quantidade e esforço por unidade" do
    pricing = @conversation.proposal.project_pricing
    message = @conversation.messages.create!(role: "user", content: "PPU")
    message.attachments.attach(io: StringIO.new(client_xlsx_bytes), filename: "PPU.xlsx")
    item = pricing.pricing_items.create!(name: "Diária embarcada", position: 5, client_quantity: 2994, client_unit: "diária", client_code: "1.1",
                                         client_sheet: { "blob_id" => message.attachments.first.blob_id, "aba" => "PPU", "celula_preco" => "F3", "celula_quantidade" => "E3" })
    pricing.proposal_professionals.create!(professional: professionals(:biologa), deliverable_name: "Observadora", pricing_item: item, man_hours: 0, field_days: 0, field_days_per_unit: 0.25)

    get conversation_proposal_path(@conversation)
    assert_select "button[form='rebuild-from-sheet-form']", text: /Reorganizar pela planilha do cliente/
    assert_select "#item-#{item.id} .badge", text: /Item 1\.1 · 2\.994 diária/
    assert_select "input[name$='[field_days_per_unit]'][value='0.25']"
    assert_select "[data-role='per-unit-days']", text: /total 748,5/
    item.update!(costs: [ { "description" => "Passagem por troca de turma", "quantity" => 214, "unit_value" => 0 } ])
    get conversation_proposal_path(@conversation)
    assert_select ".alert", text: /1 custo está sem valor unitário/

    assert_enqueued_with(job: RebuildPricingFromClientSheetJob) do
      post rebuild_from_client_sheet_conversation_proposal_path(@conversation)
    end
    assert_redirected_to conversation_proposal_path(@conversation)
  end

  test "proposta aprovada não é reorganizada" do
    @conversation.proposal.update!(status: "approved")
    assert_no_enqueued_jobs(only: RebuildPricingFromClientSheetJob) { post rebuild_from_client_sheet_conversation_proposal_path(@conversation) }
  end
end
