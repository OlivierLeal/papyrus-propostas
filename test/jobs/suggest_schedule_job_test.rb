require "test_helper"

class SuggestScheduleJobTest < ActiveJob::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
  end

  test "suggests the schedule when there is a pricing and no items yet" do
    ai_response = '{"cronograma_servico": [{"fase": "Mobilização", "atividade": "Contrato", "periodo_inicio": 1, "duracao": 1, "marco": false}], "cronograma_implantacao": []}'

    stub_ai_complete(ai_response) { SuggestScheduleJob.new.perform(@proposal.id) }

    assert_equal 1, @proposal.project_pricing.schedule_items.count
  end

  test "does nothing when a schedule already exists (idempotente)" do
    @proposal.project_pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização",
      activity_name: "Contrato", start_period: 1, duration_periods: 1, position: 0)

    assert_no_difference "@proposal.project_pricing.schedule_items.count" do
      SuggestScheduleJob.new.perform(@proposal.id)
    end
  end

  test "does nothing when the proposal has no pricing" do
    proposal = conversations(:reviewing_conversation).create_proposal!(status: "draft", version: 1)

    assert_nothing_raised { SuggestScheduleJob.new.perform(proposal.id) }
  end

  test "does not raise when the proposal id does not exist" do
    assert_nothing_raised { SuggestScheduleJob.new.perform(-1) }
  end

  test "logs and swallows the error instead of raising when the AI call fails" do
    assert_nothing_raised do
      stub_ai_error { SuggestScheduleJob.new.perform(@proposal.id) }
    end
    assert_equal 0, @proposal.project_pricing.schedule_items.count
  end

  # Relato do consultor: gerar sem cronograma e pedir "gere de novo" era ruim — o job agora
  # termina sozinho, remontando o .docx com o cronograma incluído (CLAUDE.md seção 8).
  test "auto-regenerates the docx when a document was already generated without a schedule" do
    @proposal.generated_documents.attach(
      io: StringIO.new("v1"), filename: "v1.docx", content_type: "application/octet-stream",
      metadata: { kind: "combined", version: 1, description: "Emissão Inicial" }
    )
    @proposal.update!(content_json: {
      nome_cliente: "A confirmar", contato_cliente: "A confirmar", descricao_servico: "EIA/RIMA",
      municipios: "Vitória da Conquista", estado: "BA", cnpj_cliente: "A confirmar",
      objetivo_dos_servicos: "Obter a LP.", caracterizacao_do_empreendimento: "Parque eólico.",
      nome_documento_tr: "TR", escopo_e_metodologia: "Diagnósticos.", prazo_de_execucao: "120 dias",
      produtos: [ "EIA", "RIMA" ], descricao_revisao: "Emissão Inicial"
    })
    ai_response = '{"cronograma_servico": [{"fase": "Mobilização", "atividade": "Contrato", "periodo_inicio": 1, "duracao": 1, "marco": false}], "cronograma_implantacao": []}'
    version_before = @proposal.version

    stub_ai_complete(ai_response) { SuggestScheduleJob.new.perform(@proposal.id) }

    assert_operator @proposal.reload.version, :>, version_before
    assert_equal "assistant", @proposal.conversation.messages.order(:created_at).last.role
  end
end
