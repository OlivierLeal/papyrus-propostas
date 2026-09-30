# Cabeçalho da tela da proposta (2026-09-30, repaginação): a barra de etapas e a ação principal, que
# muda sozinha conforme a etapa. Antes o botão "Avançar para Precificação" ficava perdido no meio da
# coluna lateral, entre o enquadramento e os documentos.
module ConversationWorkflowHelper
  Step = Data.define(:title, :detail, :state) # state: :done, :now, :todo
  Action = Data.define(:label, :path, :method, :enabled, :note, :note_tone) # note_tone: :warn, :ok, :muted

  def workflow_steps(conversation)
    processing = conversation.status == "processing"
    framing_done = !processing && !conversation.framing_confirmation_required?
    proposal = conversation.proposal
    documents = proposal ? latest_generated_documents(proposal) : []

    [
      Step.new("Documentos lidos", documents_step_detail(conversation), processing ? :now : :done),
      Step.new("Enquadramento", framing_step_detail(conversation), processing ? :todo : (framing_done ? :done : :now)),
      pricing_step(proposal, framing_done),
      document_step(documents)
    ]
  end

  def workflow_primary_action(conversation)
    blockers = conversation.status == "processing" ? [] : conversation.generation_blockers

    if conversation.status == "processing"
      Action.new("Processando documentos…", nil, nil, false, "A análise leva de 1 a 2 minutos", :muted)
    elsif conversation.framing_confirmation_required?
      legal = conversation.open_legal_framing_conflicts
      note = legal.any? ? "Decida a divergência de enquadramento no chat" : "Confira licença e estudos no painel ao lado"
      Action.new("Confirmar enquadramento", confirm_framing_conversation_path(conversation), :post, legal.empty?, note, :warn)
    elsif conversation.status == "reviewing"
      Action.new("Avançar para Precificação", conversation_proposal_path(conversation), :post, true,
        blockers_note(blockers) || "Enquadramento confirmado", blockers.any? ? :warn : :ok)
    else
      Action.new("Ver precificação", conversation_proposal_path(conversation), :get, true,
        blockers_note(blockers) || latest_revision_note(conversation.proposal), blockers.any? ? :warn : :muted)
    end
  end

  # Revisões mais novas primeiro; a de maior versão é a "atual".
  def latest_generated_documents(proposal)
    proposal.generated_documents.to_a.sort_by { |d| [ -(d.blob.metadata["version"] || 0), -d.created_at.to_i ] }
  end

  private

  def documents_step_detail(conversation)
    return "Analisando ET, TR e anexos" if conversation.status == "processing"

    count = conversation.messages.where(internal: false).joins(:attachments_attachments).count
    return "Resumo pronto" if count.zero?

    "#{count} #{count == 1 ? 'arquivo analisado' : 'arquivos analisados'}"
  end

  def framing_step_detail(conversation)
    return "Depois da leitura" if conversation.status == "processing"
    return "Confirmado por #{conversation.framing_confirmed_by&.name || 'consultor'}" if conversation.framing_confirmed_at
    return "Anterior à confirmação" unless conversation.framing_confirmation_required?

    "Aguardando sua confirmação"
  end

  def pricing_step(proposal, framing_done)
    return Step.new("Precificação", "Equipe, campo e preço", framing_done ? :now : :todo) unless proposal

    total = number_to_currency(proposal.project_pricing&.total_value || 0, unit: "R$", separator: ",", delimiter: ".")
    proposal.status == "approved" ? Step.new("Precificação", "#{total} · aprovado", :done) : Step.new("Precificação", "#{total} · em revisão", :now)
  end

  def document_step(documents)
    return Step.new("Proposta", "Gerar o .docx", :todo) if documents.empty?

    version = documents.first.blob.metadata["version"].to_i
    Step.new("Proposta", "Rev.#{format("%02d", [ version - 1, 0 ].max)} gerada", :done)
  end

  def blockers_note(blockers)
    return if blockers.empty?

    "#{blockers.size} #{blockers.size == 1 ? 'ponto trava' : 'pontos travam'} a geração da proposta"
  end

  def latest_revision_note(proposal)
    document = proposal && latest_generated_documents(proposal).first
    return "Nenhum documento gerado ainda — peça no chat" unless document

    "Última versão gerada #{time_ago_in_words(document.created_at)} atrás"
  end
end
