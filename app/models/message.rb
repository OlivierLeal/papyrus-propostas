class Message < ApplicationRecord
  acts_as_message chat: :conversation
  has_many_attached :attachments

  # Resultado bruto de uma tool call (SearchHistoricalArchiveTool, GenerateProposalDocumentTool
  # etc.) nasce com role "tool" e internal: false por padrão — sem isso, visto na prática em
  # produção, o JSON cru da ferramenta (ex.: os trechos do acervo histórico, com referência/
  # similaridade/origem) aparecia como uma bolha própria no chat pro consultor, porque cai no
  # fallback genérico de conversations/_message.html.erb que renderiza qualquer Hash em <dl>. A
  # mensagem continua no histórico normalmente (a IA precisa dela pra escrever a resposta final
  # citando a referência) — só não aparece pro consultor, igual às instruções internas de
  # ask_internally (ver Conversation).
  #
  # before_save (não before_create): o ruby_llm persiste em duas etapas —
  # ChatMethods#persist_new_message insere a linha já com role: :assistant (placeholder vazio,
  # antes de saber o role final) e só depois #persist_message_completion faz um UPDATE trocando
  # pra role: :tool quando é o caso. Um before_create nunca veria o role final, só o placeholder.
  before_save :hide_tool_result!

  private
    def hide_tool_result!
      self.internal = true if role == "tool"
    end
    # O KMZ é geoespacial (RGeo/PostGIS), não é lido pela IA (ver CLAUDE.md seção 3). Sem esse
    # filtro, o ruby_llm reenvia TODOS os anexos do histórico em toda chamada — e como o Gemini
    # não suporta o mime type do KMZ, isso quebra qualquer .ask()/.complete() posterior, mesmo
    # em conversas onde a instrução atual não tem nada a ver com o KMZ.
    #
    # Mesmo mecanismo por trás de um bug visto em produção: a Anthropic recusa qualquer request
    # com mais de 5 documentos no total (RubyLLM::BadRequestError "You can't include more than 5
    # documents in a request") — como o ruby_llm reenvia o histórico inteiro (Chat#to_llm), numa
    # conversa com TR + vários complementares (ou até 1 TR com bastante anexo), depois de ~5
    # documentos analisados TODA chamada seguinte passa a quebrar pra sempre — inclusive o resumo
    # e o chat normal, sem nenhum jeito de se recuperar sozinho. Cada arquivo só precisa ser lido
    # bruto UMA VEZ: a instrução que dispara a leitura sempre ganha sua própria cópia do anexo
    # (ask_internally(with: anexo) — ver Conversation#attachments_of_kind), e o resultado da
    # leitura já fica salvo como texto na resposta da IA — não precisa do arquivo bruto de novo
    # depois. Por isso só a mensagem de usuário MAIS RECENTE desta conversa (a que está "em voo",
    # sendo respondida agora) mantém anexo bruto pra IA — qualquer uma mais antiga (mensagem de
    # setup ou instrução interna já respondida) para de reenviar, mesmo continuando baixável
    # normalmente pelo consultor (isso aqui só afeta o que vai pra IA, não o Active Storage em si).
    def attachment_sources
      super.reject { |attachment, _attachable| attachment.blob.metadata["kind"] == "kmz" || stale_for_llm? }
    end

    def stale_for_llm?
      # reorder (não order): a associação messages já vem com order(created_at: :asc) padrão do
      # ruby_llm (ordem natural do chat) — .order só empilharia por cima em vez de substituir,
      # fazendo a query sempre devolver a mensagem mais ANTIGA como "mais recente" por engano.
      latest_id = conversation.messages.where(role: "user").reorder(created_at: :desc, id: :desc).limit(1).pick(:id)
      id != latest_id
    end
end
