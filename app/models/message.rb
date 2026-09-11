class Message < ApplicationRecord
  acts_as_message chat: :conversation
  has_many_attached :attachments
  belongs_to :user, optional: true

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

  # Quem digitou a mensagem, pra mostrar o nome de cada consultor no chat (2026-09 — mais de uma
  # pessoa pode acompanhar/participar da mesma proposta, ver comentário de MessagesController#
  # create sobre "outro consultor olhando a mesma proposta"). before_create (não before_save,
  # diferente de hide_tool_result! acima): mensagem "user" nasce SEMPRE com o role já definido
  # desde a criação (Conversation#create_user_message → ChatMethods#add_message → create! direto,
  # nunca o placeholder assistant-depois-atualizado que só existe pra streaming da IA), então dá
  # pra pegar Current.user já na criação. Current.user só existe dentro do ciclo de uma request —
  # fica nil (não sobrescreve nada) pra mensagens "user" internas do ask_internally (nenhum
  # humano digitou aquilo, rodam em background job) e pra mensagens antigas de antes desta coluna
  # existir; a view cai pro rótulo genérico "Você" nesses casos.
  before_create :assign_current_user, if: -> { role == "user" && user_id.nil? }

  # Códigos de citação que a IA escreveu neste texto ("[F12]"), resolvidos para os achados reais
  # desta conversa. Código que não corresponde a nenhum achado ativo daqui não vira citação: uma
  # marca inventada renderizada como se fosse fonte é pior que nenhuma fonte (ver
  # ApplicationHelper#render_markdown).
  #
  # Achado ao vivo (conversa 37, 2026-09): a IA quase sempre agrupa mais de um achado no MESMO
  # colchete quando uma frase se apoia em vários ("[F1154, F1155]") — na prática virou o formato
  # mais comum, não uma exceção. O regex antigo (`/\[F(\d+)\]/`) só casava um código sozinho por
  # colchete; um grupo como "[F1154, F1155]" não batia com ele NENHUM POUCO (a vírgula quebra o
  # match antes do "]"), então passava batido tanto por aqui quanto pela rede de segurança que
  # apaga citação residual do .docx (GenerateProposalDocumentTool#strip_citation_codes) — os
  # "[F1237]" que sobraram no texto da proposta vieram exatamente desse formato agrupado.
  # CITATION_PATTERN casa o colchete INTEIRO (um código ou vários separados por vírgula);
  # CITATION_ID_PATTERN extrai cada código de dentro de um colchete já casado.
  CITATION_PATTERN = /\[F\d+(?:,\s*F\d+)*\]/
  CITATION_ID_PATTERN = /F(\d+)/

  def cited_findings
    ids = content.to_s.scan(CITATION_PATTERN).flat_map { |group| group.scan(CITATION_ID_PATTERN) }.flatten.map(&:to_i).uniq
    return ProjectFinding.none if ids.empty?

    conversation.project_findings.active.where(id: ids).includes(:source_blob)
  end

  private
    def hide_tool_result!
      self.internal = true if role == "tool"
    end

    def assign_current_user
      self.user = Current.user
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
      # O snapshot do estado da proposta fica FORA dessa conta. Ele também é uma mensagem de
      # usuário, é escrito pelo sistema logo antes de chamar a IA (ver RespondToMessageJob) e
      # portanto nasce sempre depois da mensagem do consultor — o que fazia a mensagem dele deixar
      # de ser "a mais recente" e perder o anexo no caminho. Sintoma em uso: o consultor anexava um
      # documento e escrevia junto, o arquivo aparecia na barra lateral, e a IA respondia como se
      # só houvesse o texto.
      #
      # reorder (não order): a associação messages já vem com order(created_at: :asc) padrão do
      # ruby_llm (ordem natural do chat) — .order só empilharia por cima em vez de substituir,
      # fazendo a query sempre devolver a mensagem mais ANTIGA como "mais recente" por engano.
      latest_id = conversation.messages
        .where(role: "user")
        .where("content IS NULL OR content NOT LIKE ?", "#{Conversation::PROPOSAL_STATE_MARKER}%")
        .reorder(created_at: :desc, id: :desc).limit(1).pick(:id)
      id != latest_id
    end
end
