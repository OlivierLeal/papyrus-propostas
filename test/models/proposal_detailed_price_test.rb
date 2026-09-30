require "test_helper"

# Quadro de Preço detalhado (2026-09-30, pedido do cliente: "tem cliente que quer saber valor de HH,
# logística detalhada, BDI, impostos, tudo separado").
class ProposalDetailedPriceTest < ActiveSupport::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @pricing = @proposal.project_pricing
    @pricing.update!(price_presentation: "detalhado", bdi: 1.3, tax_multiplier: 1.25,
      external_costs: [ { "description" => "Taxa de análise do órgão", "value" => 500 },
                        { "description" => "Levantamento de fauna – Empresa X", "value" => 2000, "kind" => "terceirizado" } ])
    @pricing.recalculate!
    @rows = @proposal.reload.docx_price_rows
  end

  def money(text) = text.delete(".").tr(",", ".").to_d

  test "vale mesmo com um item só (não cai pro preço total)" do
    assert_equal "detalhado", @proposal.price_presentation_mode
    assert @rows.size > 3
  end

  test "linhas de custo mostram quantidade × valor e somam o subtotal do custo direto" do
    hh = @rows.find { |_, label, _| label.start_with?("Horas-homem:") }
    assert_match(/HH × R\$ \d/, hh[1])

    subtotal_index = @rows.index { |_, label, _| label == "SUBTOTAL – CUSTO DIRETO" }
    cost_lines = @rows[0...subtotal_index].reject { |number, _, _| number.blank? }
    assert_equal money(@rows[subtotal_index][2]), cost_lines.sum { |_, _, value| money(value) }
  end

  test "custo direto + BDI + impostos + externos = TOTAL, e só linhas de custo são numeradas" do
    total = @rows.last
    assert_equal [ "", "TOTAL" ], total.first(2)
    assert_equal @pricing.total_value.to_d, money(total[2])

    subtotal_index = @rows.index { |_, label, _| label == "SUBTOTAL – CUSTO DIRETO" }
    after = @rows[subtotal_index..-2].sum { |_, _, value| money(value) }
    assert_equal money(total[2]), after
    assert_equal "", @rows[subtotal_index].first
    assert @rows.find { |_, label, _| label.start_with?("BDI (× 1,30)") }
    assert @rows.find { |_, label, _| label.start_with?("Impostos e despesas administrativas (× 1,25)") }
  end

  test "serviço terceirizado não aparece com a descrição dele" do
    labels = @rows.map { |_, label, _| label }

    assert_includes labels, "Taxa de análise do órgão"
    assert_includes labels, "Serviços especializados"
    assert labels.none? { |label| label.include?("Empresa X") }
  end
end
