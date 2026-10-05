require "test_helper"

class ProposalProfessionalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:two)
    @conversation = conversations(:priced_conversation)
    @pricing = proposals(:priced_proposal).project_pricing
  end

  test "create adds a line added by hand and recalculates the total" do
    assert_difference "@pricing.proposal_professionals.count", 1 do
      post conversation_proposal_proposal_professionals_path(@conversation), params: {
        proposal_professional: {
          professional_id: professionals(:inativo).id, deliverable_name: "Consultoria extra", man_hours: "10", field_days: "0"
        }
      }
    end

    assert_redirected_to conversation_proposal_path(@conversation)
    line = @pricing.proposal_professionals.order(:created_at).last
    assert_equal 10 * professionals(:inativo).rate_man_hour * @pricing.bdi * @pricing.tax_multiplier, line.subtotal
  end

  # 2026-10: "+ Novo item…" no "Adicionar à equipe" cria o item junto com a linha.
  test "create com item novo cria o item e põe a linha nele; sem nome, não cria nada" do
    assert_difference [ "@pricing.pricing_items.count", "@pricing.proposal_professionals.count" ], 1 do
      post conversation_proposal_proposal_professionals_path(@conversation), params: {
        proposal_professional: { professional_id: professionals(:biologa).id, deliverable_name: "Fauna", pricing_item_id: "new", man_hours: "8", field_days: "0" },
        new_item_name: "  Diagnóstico de Fauna  "
      }
    end
    item = @pricing.pricing_items.order(:position).last
    assert_equal "Diagnóstico de Fauna", item.name
    assert_equal item, @pricing.proposal_professionals.order(:id).last.pricing_item

    assert_no_difference [ "@pricing.pricing_items.count", "@pricing.proposal_professionals.count" ] do
      post conversation_proposal_proposal_professionals_path(@conversation), params: {
        proposal_professional: { professional_id: professionals(:biologa).id, deliverable_name: "Fauna", pricing_item_id: "new", man_hours: "8", field_days: "0" },
        new_item_name: ""
      }
    end
    assert_equal "Informe o nome do novo item", flash[:alert]
  end

  test "create rejects a line with no deliverable_name" do
    assert_no_difference "@pricing.proposal_professionals.count" do
      post conversation_proposal_proposal_professionals_path(@conversation), params: {
        proposal_professional: { professional_id: professionals(:inativo).id, deliverable_name: "", man_hours: "10", field_days: "0" }
      }
    end

    assert_redirected_to conversation_proposal_path(@conversation)
  end

  test "destroy removes the line and recalculates the total" do
    line = proposal_professionals(:coordenacao_line)

    assert_difference "@pricing.proposal_professionals.count", -1 do
      delete conversation_proposal_proposal_professional_path(@conversation, line)
    end

    assert_redirected_to conversation_proposal_path(@conversation)
    assert_not_includes @pricing.reload.proposal_professionals, line
  end

  test "destroy recusa remover a única linha de um profissional fixo" do
    line = @pricing.proposal_professionals.create!(professional: professionals(:diretora), deliverable_name: "Direção", man_hours: 0, field_days: 0)

    assert_no_difference "@pricing.proposal_professionals.count" do
      delete conversation_proposal_proposal_professional_path(@conversation, line)
    end

    assert_redirected_to conversation_proposal_path(@conversation)
    assert_match "equipe fixa", flash[:alert]
  end

  test "destroy permite remover linha extra de um fixo, mantendo a pessoa na equipe" do
    @pricing.proposal_professionals.create!(professional: professionals(:diretora), deliverable_name: "Direção", man_hours: 0, field_days: 0)
    extra = @pricing.proposal_professionals.create!(professional: professionals(:diretora), deliverable_name: "Revisão final", man_hours: 4, field_days: 0)

    assert_difference "@pricing.proposal_professionals.count", -1 do
      delete conversation_proposal_proposal_professional_path(@conversation, extra)
    end
    assert @pricing.proposal_professionals.exists?(professional: professionals(:diretora))
  end

  test "create e destroy recusam proposta aprovada" do
    proposals(:priced_proposal).update!(status: "approved")

    assert_no_difference "@pricing.proposal_professionals.count" do
      post conversation_proposal_proposal_professionals_path(@conversation), params: {
        proposal_professional: { professional_id: professionals(:biologa).id, deliverable_name: "X", man_hours: "1", field_days: "0" }
      }
      delete conversation_proposal_proposal_professional_path(@conversation, proposal_professionals(:coordenacao_line))
    end
  end
end
