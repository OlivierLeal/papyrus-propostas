class RespondToMessageJob < ApplicationJob
  queue_as :default

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    conversation.refresh_proposal_state_snapshot!
    before_message_ids = conversation.messages.ids
    docs_before = generated_docs_count(conversation)

    # Sempre registrada, mesmo sem proposal ainda — ela cria a proposta sozinha na primeira vez
    # que é chamada de verdade (ver GenerateProposalDocumentTool#execute/Conversation#ensure_
    # proposal!), então não depende mais do consultor clicar em "Avançar para Precificação" antes.
    conversation.with_tool(GenerateProposalDocumentTool.new(conversation: conversation))
    conversation.with_tool(AddExternalCostTool.new(proposal: conversation.proposal)) if conversation.proposal
    # Inserir só a seção de cronograma num .docx finalizado que o consultor anexou (proposta
    # gerada pelo sistema e revisada por fora — ver CLAUDE.md seção 8).
    conversation.with_tool(InsertScheduleSectionTool.new(proposal: conversation.proposal)) if conversation.proposal
    # Consulta ao acervo histórico (CLAUDE.md seção 11.1). Só é registrada quando há acervo
    # indexado — sem isso a IA "descobre" uma ferramenta que sempre volta vazia e passa a
    # mencionar buscas que não trouxeram nada.
    conversation.with_tool(SearchHistoricalArchiveTool.new) if HistoricalProposalChunk.embedded.exists?
    # CAL (Ius Natura, ver app/services/cal/) — só registrada com credenciais configuradas, mesmo
    # motivo do acervo acima: ferramenta que sempre falha vira algo que a IA acha que tentou.
    conversation.with_tool(SearchLegalNormsTool.new) if Cal::Client.configured?
    # Legislação já lida e guardada (LegalNorm/LegalNormChunk) — mesmo critério do acervo acima:
    # só oferece quando há algo pra achar.
    conversation.with_tool(SearchLegalNormsArchiveTool.new) if LegalNormChunk.embedded.exists?
    conversation.with_tool(RememberForFutureProposalsTool.new(conversation: conversation))
    # Aprender com a versão final revisada manualmente pela Papyrus, quando anexada no chat (ver
    # CLAUDE.md seção 11.1) — mesma disciplina de curadoria da ferramenta acima, card pendente até
    # o consultor aprovar.
    conversation.with_tool(LearnFromRevisedProposalTool.new(conversation: conversation))
    # #complete_with_lock, nunca #complete cru — serializa este turno contra qualquer
    # #ask_internally concorrente na MESMA conversa (ex.: SuggestScheduleJob, enfileirado de
    # dentro de uma tool call deste turno, ver Conversation#complete_with_lock).
    conversation.complete_with_lock

    conversation.broadcast_remove_to conversation, target: "typing_indicator"

    # Se alguma tool call gerou/anexou documento (GenerateProposalDocumentTool,
    # InsertScheduleSectionTool), a barra lateral "Documentos" e o histórico só apareciam com F5:
    # o broadcast_refresh saía de DENTRO da tool call, ou seja, DENTRO da transação do
    # `with_ai_lock` (complete_with_lock) — o navegador re-buscava a página antes do commit e via
    # o estado velho, sem o arquivo novo (achado ao vivo: "às vezes tenho que dar F5"). Aqui já
    # está commitado. Um refresh (morph) já traz as mensagens novas + os documentos + a sidebar,
    # então dispensa o append por mensagem.
    if generated_docs_count(conversation.reload) != docs_before
      conversation.broadcast_refresh
      return
    end

    # Não só a última: RememberForFutureProposalsTool (e qualquer ferramenta que crie um card, ver
    # ProjectConflict) grava uma mensagem assistant PRÓPRIA para o card, separada da resposta em
    # texto — sem broadcast dela aqui, o card só aparecia depois de um F5 na página. animate só na
    # última (o texto que a IA realmente escreveu); um card não precisa do efeito de máquina de
    # escrever.
    new_messages = conversation.messages.where(role: "assistant", internal: false)
      .where.not(id: before_message_ids).order(:created_at)
    return if new_messages.none?

    new_messages.each do |message|
      conversation.broadcast_append_to conversation, target: "messages", partial: "conversations/message",
        locals: { message: message, animate: message == new_messages.last }
    end
  rescue StandardError => e
    Rails.logger.error("RespondToMessageJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    return unless conversation

    conversation.broadcast_remove_to conversation, target: "typing_indicator"
    conversation.broadcast_append_to conversation, target: "messages", partial: "conversations/error_bubble",
      locals: { text: error_text_for(e) }
  end

  private
    def generated_docs_count(conversation)
      conversation.proposal&.generated_documents&.count || 0
    end

    # Não persiste como Message — isso entraria no histórico enviado de volta pra IA em toda
    # chamada futura (ver Conversation#to_llm). É só um aviso visual, some se a página recarregar.
    def error_text_for(error)
      return "Não consegui responder agora — o limite de requisições da IA foi atingido. Tente novamente em alguns minutos." if error.is_a?(RubyLLM::RateLimitError)

      "Não consegui responder agora. Tente novamente em instantes."
    end
end
