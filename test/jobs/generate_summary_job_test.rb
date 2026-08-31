require "test_helper"

class GenerateSummaryJobTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:processing_conversation)
    @conversation.update!(processing_steps: { "et" => "done", "tr" => "skipped", "comp_docs" => "skipped", "summary" => "queued" })
  end

  def record_finding!(field:, value:, source_kind: "tr", nature: "fato", excerpt: nil)
    @conversation.project_findings.create!(
      field: field, value: value, source_kind: source_kind, nature: nature, excerpt: excerpt
    )
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

  test "includes the recorded findings, with their citation codes, in the prompt" do
    finding = record_finding!(field: "tipo_licenca", value: "LP")

    stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "Tipo de licença"
    assert_includes sent_prompt, "[#{finding.citation_code}] Tipo de licença: LP"
  end

  # O resumo é montado a partir dos achados registrados, não do texto solto que a IA escreveu
  # antes no chat — era daí que vinha a informação sem origem.
  test "builds the summary from findings, not from free assistant text" do
    @conversation.messages.create!(role: "assistant", content: "isso não é json, é texto livre", internal: true)
    record_finding!(field: "tipo_licenca", value: "LP")

    stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "Tipo de licença: LP"
    assert_not_includes sent_prompt, "isso não é json"
  end

  # O trecho fica FORA do prompt de propósito: ele é para o consultor conferir no chip, e repeti-lo
  # a cada turno custaria contexto.
  test "the prompt carries the citation code but not the excerpt" do
    record_finding!(field: "orgao_ambiental", value: "INEMA", excerpt: "...protocolo junto ao INEMA, conforme...")

    stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_not_includes sent_prompt, "protocolo junto ao INEMA"
  end

  test "opens a card in the chat for each divergence found between documents" do
    record_finding!(field: "area_ha", value: "500", source_kind: "tr")
    record_finding!(field: "area_ha", value: "620", source_kind: "sistema")

    stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }

    conflict = @conversation.project_conflicts.sole
    assert_equal "open", conflict.status
    assert_includes @conversation.messages.map(&:content), { project_conflict_id: conflict.id }.to_json

    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content
    assert_includes sent_prompt, "DIVERGÊNCIAS ENTRE OS DOCUMENTOS"
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
    record_finding!(field: "tipo_licenca", value: "Licença Unificada (LU)")
    record_finding!(field: "orgao_ambiental", value: "INEMA")
    record_finding!(field: "empreendimento", value: "sistema de armazenamento de energia em baterias (BESS)")
    record_finding!(field: "municipios", value: "Morro do Chapéu")
    record_finding!(field: "diagnosticos", value: "fauna")
    record_finding!(field: "diagnosticos", value: "flora")
    # O tipo do documento complementar (carta de encaminhamento) cai em "outro", que fica fora do
    # descritor justamente por ser vocabulário de carta.
    record_finding!(field: "outro", value: "Encaminhamento via Charlene Luz da solicitação de Guilherme Altino (Rio Energy)")

    context = GenerateSummaryJob.new.send(:search_context, @conversation.reload)

    assert_includes context, "tipo licenca: Licença Unificada (LU)"
    assert_includes context, "empreendimento: sistema de armazenamento de energia em baterias (BESS)"
    assert_includes context, "diagnosticos: fauna; flora"
    assert_includes context, "tipo estudo: #{study_types(:eia_rima).name}"
    assert_not_includes context, "Rio Energy", "nome do cliente é faceta, não semântica"
    assert_not_includes context, "Charlene", "carta de encaminhamento não descreve o serviço"
  end

  test "cada campo do descritor tem orçamento próprio, em vez de um corte cego no fim" do
    record_finding!(field: "empreendimento", value: "x" * 1000)
    record_finding!(field: "ressalvas", value: "não há supressão de vegetação")

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
