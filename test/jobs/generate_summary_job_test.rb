require "test_helper"

class GenerateSummaryJobTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:processing_conversation)
    @conversation.update!(processing_steps: { "tr" => "done", "comp_docs" => "skipped", "summary" => "queued" })
  end

  test "asks the AI for a summary, marks summary done and moves status to reviewing" do
    stub_ai_complete("# RESUMO ESTRUTURADO\n\nTudo certo.") { GenerateSummaryJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("summary")
    assert_equal "reviewing", @conversation.status
  end

  test "the summary reply is visible to the consultant, only the instruction is hidden" do
    stub_ai_complete("# RESUMO ESTRUTURADO") { GenerateSummaryJob.perform_now(@conversation.id) }

    instruction = @conversation.messages.where(role: "user", internal: true).last
    reply = @conversation.messages.where(role: "assistant").last

    assert instruction.present?
    assert_not reply.internal?
  end

  test "includes parsed JSON findings from prior assistant messages in the prompt" do
    @conversation.messages.create!(role: "assistant", content: '{"tipo_licenca": "LP", "diagnosticos": ["fauna", "flora"]}', internal: true)

    sent_prompt = nil
    stub_ai_complete("ok") do
      GenerateSummaryJob.perform_now(@conversation.id)
    end
    # A instrução enviada é a última mensagem "user" internal antes da resposta.
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "tipo_licenca: LP"
    assert_includes sent_prompt, "diagnosticos: fauna; flora"
  end

  test "ignores prior assistant messages whose content isn't valid JSON" do
    @conversation.messages.create!(role: "assistant", content: "isso não é json, é texto livre", internal: true)
    @conversation.messages.create!(role: "assistant", content: '{"tipo_licenca": "LP"}', internal: true)

    stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "tipo_licenca: LP"
    assert_not_includes sent_prompt, "isso não é json"
  end

  test "includes the geospatial summary in the prompt when a GeospatialResult exists" do
    @conversation.create_geospatial_result!(area_ha: 478.07, perimeter_km: 8.75)

    stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "Área: 478.07 ha"
    assert_includes sent_prompt, "Perímetro: 8.75 km"
  end

  test "omits the geospatial section entirely when there is no GeospatialResult" do
    stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_not_includes sent_prompt, "Dados geoespaciais"
  end

  test "falls back to a placeholder message when there is no structured data yet" do
    sent_prompt = nil
    stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "Nenhum dado estruturado disponível ainda."
  end

  test "marks summary as failed and does not raise when the AI call errors out" do
    stub_ai_error { GenerateSummaryJob.perform_now(@conversation.id) }

    assert_equal "failed", @conversation.reload.processing_step_status("summary")
    assert_equal "processing", @conversation.status # não avança de status quando falha
  end

  # DESCRITOR DE SERVIÇO (busca no acervo). O que vai para o embedding é só o que descreve o
  # serviço — cliente, contato, prazo e nome de arquivo ficam de fora, porque era esse
  # vocabulário de carta que puxava a recuperação para a CAPA das propostas antigas.
  test "a busca no acervo usa só os campos que descrevem o serviço" do
    @conversation.update!(client_name: "Rio Energy", study_type: study_types(:eia_rima))
    @conversation.messages.create!(role: "assistant", internal: true, content: {
      tipo_licenca: "Licença Unificada (LU)", orgao_ambiental: "INEMA",
      empreendimento: "sistema de armazenamento de energia em baterias (BESS)",
      municipios: [ "Morro do Chapéu" ], diagnosticos: [ "fauna", "flora" ],
      resumo: "Encaminhamento via Charlene Luz da solicitação de Guilherme Altino (Rio Energy)"
    }.to_json)

    context = GenerateSummaryJob.new.send(:search_context, @conversation.reload)

    assert_includes context, "tipo licenca: Licença Unificada (LU)"
    assert_includes context, "empreendimento: sistema de armazenamento de energia em baterias (BESS)"
    assert_includes context, "diagnosticos: fauna; flora"
    assert_includes context, "tipo estudo: #{study_types(:eia_rima).name}"
    assert_not_includes context, "Rio Energy", "nome do cliente é faceta, não semântica"
    assert_not_includes context, "Charlene", "carta de encaminhamento não descreve o serviço"
  end

  test "cada campo do descritor tem orçamento próprio, em vez de um corte cego no fim" do
    @conversation.messages.create!(role: "assistant", internal: true, content: {
      empreendimento: "x" * 1000, ressalvas: [ "não há supressão de vegetação" ]
    }.to_json)

    context = GenerateSummaryJob.new.send(:search_context, @conversation.reload)

    assert_includes context, "ressalvas: não há supressão de vegetação",
      "o campo do fim não pode ser comido pelo excesso do campo anterior"
  end

  test "diz ao consultor quando o acervo não tem projeto parecido, em vez de omitir o tópico" do
    with_similar_jobs([]) do
      stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }
    end
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "nenhum projeto anterior semelhante"
  end

  test "apresenta o projeto semelhante por confiança, sem porcentagem de similaridade" do
    match = Rag::SimilarJobFinder::Match.new(
      job_number: "25051", client_name: "Petrobras", subject: "Diagnóstico Quilombola", year: 2025,
      strength: 0.10, dominance: 0.9, sections: [ "4. ESCOPO" ], documents: [ "a.docx" ]
    )

    with_similar_jobs([ match ]) do
      stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }
    end
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "25051 · Petrobras · Diagnóstico Quilombola (2025) — referência direta"
    assert_no_match(/similaridade \d+%/, sent_prompt)
  end

  private

    # Mesmo padrão dos outros testes do projeto (ver MapboxStaticMapTest): troca o método na
    # classe e devolve no ensure, sem depender de biblioteca de mock.
    def with_similar_jobs(matches)
      original = Rag::SimilarJobFinder.method(:new)
      fake = FakeFinder.new(matches)
      Rag::SimilarJobFinder.define_singleton_method(:new) { |*, **| fake }
      yield
    ensure
      Rag::SimilarJobFinder.define_singleton_method(:new, original)
    end

    FakeFinder = Struct.new(:matches) do
      def call(_context, **) = matches
    end
end
