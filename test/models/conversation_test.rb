require "test_helper"

class ConversationTest < ActiveSupport::TestCase
  test "requires client_name" do
    conversation = Conversation.new(user: users(:one), study_type: study_types(:eia_rima))
    assert_not conversation.valid?
    assert_includes conversation.errors[:client_name], "não pode ficar em branco"
  end

  test "study_type is optional — não é escolhido no setup, a IA identifica lendo a TR" do
    conversation = Conversation.new(user: users(:one), client_name: "Cliente Teste")
    assert conversation.valid?
    assert_nil conversation.study_type_id
  end

  test "requires a valid status" do
    conversation = conversations(:reviewing_conversation)
    conversation.status = "estado_invalido"
    assert_not conversation.valid?
  end

  test "status_label translates the status to Portuguese" do
    conversation = conversations(:reviewing_conversation)
    assert_equal "Em revisão", conversation.status_label
  end

  # REGRESSÃO — achado em produção (chat 30, 2026-09-01): o consultor marcou o tipo de estudo pela
  # tela ENQUANTO o RespondToMessageJob da mensagem "gere a proposta" já estava rodando com a
  # Conversation carregada no início do job — a resposta da IA levou dezenas de segundos, tempo de
  # sobra pro update concorrente gravar no banco. Sem reload, a ferramenta via o objeto antigo
  # (study_type ainda nil em memória) mesmo já estando gravado no banco havia bom tempo, e recusava
  # gerar a proposta com "ET ainda em processamento" — mensagem enganosa, já que o ET tinha
  # terminado fazia tempo; o problema era só o objeto em memória estar desatualizado.
  test "ensure_proposal! reloads before checking, catching a study_type set by a concurrent request while this job was running" do
    conversation = Conversation.create!(user: users(:one), client_name: "Corrida de Concorrência", status: "reviewing")
    stale_copy = Conversation.find(conversation.id) # simula o objeto já carregado pelo job, antes do update concorrente

    conversation.update!(study_type: study_types(:eia_rima)) # "outra requisição" (a tela) atualiza o banco enquanto o job roda

    assert_nil stale_copy.study_type_id # confirma que o objeto em memória está mesmo desatualizado, sem reload nenhum ainda

    proposal = stub_ai_error { stale_copy.ensure_proposal! }

    assert proposal.present?
    assert_equal study_types(:eia_rima), stale_copy.study_type
  end

  test "ensure_proposal! returns nil (without reloading forever) when the study_type still isn't set anywhere" do
    conversation = Conversation.create!(user: users(:one), client_name: "Sem Tipo Nenhum", status: "reviewing")

    assert_nil conversation.ensure_proposal!
  end

  test "apply_system_instructions! creates two hidden system messages" do
    conversation = conversations(:processing_conversation)
    # Fixtures inserem via SQL puro e pulam callbacks — o before_save que resolve o Model (ruby_llm)
    # só roda com um save de verdade, senão to_llm quebra tentando ler model_association.model_id.
    conversation.save!

    conversation.apply_system_instructions!

    system_messages = conversation.messages.where(role: "system")
    assert_equal 2, system_messages.count
    assert system_messages.all?(&:internal?)
  end

  test "ask_internally hides the instruction but keeps the reply visible by default" do
    conversation = conversations(:processing_conversation)

    stub_ai_complete("resposta da IA") do
      conversation.ask_internally("pergunta interna")
    end

    instruction = conversation.messages.where(role: "user").order(:created_at).last
    reply = conversation.messages.where(role: "assistant").order(:created_at).last

    assert instruction.internal?
    assert_not reply.internal?
    assert_equal "resposta da IA", reply.content
  end

  test "ask_internally with hide_response also hides the reply" do
    conversation = conversations(:processing_conversation)

    stub_ai_complete("json escondido") do
      conversation.ask_internally("pergunta interna", hide_response: true)
    end

    reply = conversation.messages.where(role: "assistant").order(:created_at).last
    assert reply.internal?
  end

  test "attachments_of_kind filters by the blob metadata kind" do
    conversation = conversations(:reviewing_conversation)
    message = conversation.messages.first
    message.attachments.attach(
      io: StringIO.new("conteúdo"), filename: "tr.pdf", content_type: "application/pdf",
      metadata: { kind: "tr" }
    )
    message.attachments.attach(
      io: StringIO.new("conteúdo"), filename: "extra.pdf", content_type: "application/pdf",
      metadata: { kind: "complementary" }
    )

    assert_equal [ "tr.pdf" ], conversation.attachments_of_kind("tr").map { |a| a.filename.to_s }
    assert_equal "tr.pdf", conversation.attachment_of_kind("tr").filename.to_s
  end

  test "attachments_of_kind ignores copies ruby_llm persists onto the internal instruction message" do
    conversation = conversations(:reviewing_conversation)
    message = conversation.messages.first
    message.attachments.attach(
      io: StringIO.new("conteúdo"), filename: "tr.pdf", content_type: "application/pdf",
      metadata: { kind: "tr" }
    )
    attachment = conversation.attachments_of_kind("tr").first

    # ask_internally(with: attachment) faz o ruby_llm persistir uma cópia do anexo na própria
    # mensagem de instrução (internal: true) — sem o filtro em attachments_of_kind, esse anexo
    # "dobra" de contagem depois dessa chamada.
    stub_ai_complete("ok") { conversation.ask_internally("instrução interna", with: attachment) }

    assert_equal 1, conversation.attachments_of_kind("tr").size
  end

  test "mark_step! merges the step atomically and keeps other steps untouched" do
    conversation = conversations(:processing_conversation)

    conversation.mark_step!("et", "done")

    assert_equal "done", conversation.reload.processing_step_status("et")
    assert_equal "skipped", conversation.processing_step_status("comp_docs")
  end

  test "check_processing_complete! enqueues GenerateSummaryJob once et and comp_docs are resolved" do
    conversation = conversations(:processing_conversation)
    conversation.mark_step!("et", "done")

    assert_enqueued_with(job: GenerateSummaryJob, args: [ conversation.id ]) do
      conversation.check_processing_complete!
    end
  end

  test "check_processing_complete! does not enqueue twice" do
    conversation = conversations(:processing_conversation)
    conversation.mark_step!("et", "done")
    conversation.check_processing_complete!

    assert_no_enqueued_jobs only: GenerateSummaryJob do
      conversation.check_processing_complete!
    end
  end

  test "refresh_proposal_state_snapshot! without a proposal tells the AI the proposal doesn't exist yet, not to fake calling the tool" do
    # Achado num caso real: sem essa mensagem, a IA não tinha como saber que a proposta ainda não
    # existe (GenerateProposalDocumentTool nem está registrada nesse ponto) e inventava que tinha
    # chamado a ferramenta de geração — ver RespondToMessageJob.
    conversation = conversations(:reviewing_conversation)

    conversation.refresh_proposal_state_snapshot!

    marker = conversation.messages.where(role: "user", internal: true).where("content LIKE ?", "[ESTADO ATUAL DA PROPOSTA]%").last
    assert marker.present?
    assert_includes marker.content, "AINDA NÃO FOI CRIADA"
  end

  test "refresh_proposal_state_snapshot! replaces the previous marker instead of accumulating, with or without a proposal" do
    conversation = conversations(:reviewing_conversation)

    conversation.refresh_proposal_state_snapshot!
    conversation.refresh_proposal_state_snapshot!

    markers = conversation.messages.where(role: "user", internal: true).where("content LIKE ?", "[ESTADO ATUAL DA PROPOSTA]%")
    assert_equal 1, markers.count
  end

  test "refresh_proposal_state_snapshot! creates a single hidden marker reflecting the pricing state" do
    conversation = conversations(:priced_conversation)

    conversation.refresh_proposal_state_snapshot!
    conversation.refresh_proposal_state_snapshot!

    markers = conversation.messages.where(role: "user", internal: true).where("content LIKE ?", "[ESTADO ATUAL DA PROPOSTA]%")
    assert_equal 1, markers.count
    assert_includes markers.first.content, "Preço total calculado"
  end

  # Sem isso a IA reenvia (ou pior, re-pergunta) o nome do arquivo a cada geração, mesmo o
  # consultor já tendo dito uma vez.
  test "refresh_proposal_state_snapshot! says whether the filename was dictated by the consultant" do
    conversation = conversations(:priced_conversation)

    conversation.refresh_proposal_state_snapshot!
    assert_includes conversation.messages.where(role: "user", internal: true).last.content, "padrão do sistema"

    conversation.proposal.update!(docx_filename_override: "PTC26002_PMM_LU")
    conversation.refresh_proposal_state_snapshot!
    marker = conversation.messages.where(role: "user", internal: true).last.content

    assert_includes marker, "definido pelo consultor"
    assert_includes marker, "PTC26002_PMM_LU"
  end

  # O que a IA sabe sobre o projeto tem que caber num lugar só, reconstruído a cada turno — senão
  # ela cita achado que já foi superado ou ignora divergência que o consultor ainda não decidiu.
  test "refresh_proposal_state_snapshot! carries the findings with their citation codes" do
    conversation = conversations(:reviewing_conversation)
    finding = conversation.project_findings.create!(
      field: "orgao_ambiental", value: "INEMA", nature: "fato", source_kind: "tr",
      excerpt: "...protocolo junto ao INEMA..."
    )

    conversation.refresh_proposal_state_snapshot!
    marker = conversation.messages.where(role: "user", internal: true).last

    assert_includes marker.content, "[ACHADOS DESTA PROPOSTA]"
    assert_includes marker.content, "[#{finding.citation_code}] Órgão ambiental: INEMA"
    assert_not_includes marker.content, "protocolo junto ao INEMA", "o trecho é para o consultor ver no chip, não para gastar contexto a cada turno"
  end

  test "refresh_proposal_state_snapshot! tells the AI to treat an open divergence as a caveat, never to pick a side" do
    conversation = conversations(:reviewing_conversation)
    tr = conversation.project_findings.create!(field: "area_ha", value: "500", nature: "fato", source_kind: "tr")
    kmz = conversation.project_findings.create!(field: "area_ha", value: "620", nature: "fato", source_kind: "sistema")
    conflict = conversation.project_conflicts.create!(field: "area_ha", summary: "Áreas diferentes.")
    [ tr, kmz ].each { |f| conflict.project_conflict_findings.create!(project_finding: f) }

    conversation.refresh_proposal_state_snapshot!
    marker = conversation.messages.where(role: "user", internal: true).last

    assert_includes marker.content, "[DIVERGÊNCIAS ABERTAS ENTRE OS DOCUMENTOS]"
    assert_includes marker.content, "NUNCA escolha um dos valores sozinho"
    assert_includes marker.content, "Isso NÃO impede gerar a proposta."
  end

  test "a divergence already decided leaves the snapshot" do
    conversation = conversations(:reviewing_conversation)
    conversation.project_conflicts.create!(field: "area_ha", summary: "Áreas diferentes.", status: "dismissed")

    conversation.refresh_proposal_state_snapshot!

    assert_not_includes conversation.messages.where(role: "user", internal: true).last.content, "DIVERGÊNCIAS ABERTAS"
  end
end
