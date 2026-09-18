require "test_helper"

class RegenerateScheduleJobTest < ActiveJob::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @proposal.project_pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Antigo",
      activity_name: "Fase de 12 meses", start_period: 1, duration_periods: 52, position: 0)
  end

  test "replaces the existing schedule with the new AI suggestion, unlike SuggestScheduleJob" do
    ai_response = '{"cronograma_servico": [{"fase": "Novo", "atividade": "Fase de 6 meses", "periodo_inicio": 1, "duracao": 26, "marco": false}], "cronograma_implantacao": []}'

    stub_ai_complete(ai_response) { RegenerateScheduleJob.new.perform(@proposal.id) }

    items = @proposal.project_pricing.schedule_items.for_type("servico").to_a
    assert_equal [ "Fase de 6 meses" ], items.map(&:activity_name)
  end

  test "does not touch the schedule when the proposal has no pricing" do
    proposal = conversations(:reviewing_conversation).create_proposal!(status: "draft", version: 1)

    assert_nothing_raised { RegenerateScheduleJob.new.perform(proposal.id) }
  end

  test "does not raise when the proposal id does not exist" do
    assert_nothing_raised { RegenerateScheduleJob.new.perform(-1) }
  end

  test "logs and swallows the error, keeping the existing schedule, when the AI call fails" do
    assert_nothing_raised do
      stub_ai_error { RegenerateScheduleJob.new.perform(@proposal.id) }
    end
    assert_equal [ "Fase de 12 meses" ], @proposal.project_pricing.schedule_items.for_type("servico").map(&:activity_name)
  end

  # Relato do consultor: pedir "atualizar_cronograma" e depois ter que pedir "gere de novo" pra
  # ver o resultado era ruim — o job agora termina sozinho (CLAUDE.md seção 8).
  test "auto-regenerates the docx after rebuilding the schedule" do
    @proposal.generated_documents.attach(
      io: StringIO.new("v1"), filename: "v1.docx", content_type: "application/octet-stream",
      metadata: { kind: "combined", version: 1, description: "Emissão Inicial" }
    )
    @proposal.update!(content_json: {
      nome_cliente: "A confirmar", contato_cliente: "A confirmar", descricao_servico: "EIA/RIMA",
      municipios: "Vitória da Conquista", estado: "BA", cnpj_cliente: "A confirmar",
      objetivo_dos_servicos: "Obter a LP.", caracterizacao_do_empreendimento: "Parque eólico.",
      nome_documento_tr: "TR", escopo_e_metodologia: "Diagnósticos.", prazo_de_execucao: "120 dias",
      produtos: [ "EIA", "RIMA" ], descricao_revisao: "Emissão Inicial", atualizar_cronograma: true
    })
    ai_response = '{"cronograma_servico": [{"fase": "Novo", "atividade": "Fase de 6 meses", "periodo_inicio": 1, "duracao": 26, "marco": false}], "cronograma_implantacao": []}'
    version_before = @proposal.version

    stub_ai_complete(ai_response) { RegenerateScheduleJob.new.perform(@proposal.id) }

    assert_operator @proposal.reload.version, :>, version_before
    assert_equal "assistant", @proposal.conversation.messages.order(:created_at).last.role
  end
end
