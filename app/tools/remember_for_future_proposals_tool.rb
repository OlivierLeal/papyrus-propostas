# Deixa a IA PROPOR que algo aprendido nesta conversa seja guardado para as próximas propostas.
#
# A ferramenta não grava conhecimento: ela cria uma nota PENDENTE e devolve isso ao chat, onde o
# consultor decide com um clique. A diferença importa — o valor do acervo vem de tudo nele ter
# sido escrito por gente, e uma inferência da IA gravada direto voltaria meses depois citada
# como "memória da Papyrus", indistinguível de um fato verificado.
#
# Ver KnowledgeNote e ProposeKnowledgeNote no chat.
class RememberForFutureProposalsTool < RubyLLM::Tool
  description <<~DESC
    Registra, para APROVAÇÃO do consultor, uma informação desta conversa que vale a pena lembrar
    em propostas futuras. Use quando aparecer algo que se repetirá e que hoje só existe neste
    chat, por exemplo:

    - uma exigência ou preferência recorrente do cliente;
    - uma decisão de escopo ou metodologia que deu certo e vale repetir;
    - uma condicionante ou ressalva do órgão ambiental;
    - uma correção que o consultor fez em você e que você deve lembrar.

    NÃO use para: informação que já está no TR (ela vive na proposta), fato pontual deste
    projeto que não se repete, nem nada que você deduziu sem confirmação. Na dúvida, não
    registre — nota errada aprovada vira "conhecimento da Papyrus" e contamina propostas futuras.

    A informação NÃO é guardada na hora: ela vai para o consultor aprovar. Ao chamar esta
    ferramenta, diga ao consultor o que você propôs guardar e por quê.
  DESC

  param :categoria,
    desc: 'Uma de: "preferencia_cliente", "escopo_metodologia", "condicionante_orgao", "correcao_consultor"'
  param :informacao,
    desc: "A informação a lembrar, escrita de forma autoexplicativa — ela será lida daqui a meses, " \
          "fora desta conversa, por isso não use \"ele\", \"esse projeto\" ou \"como falamos acima\""
  param :contexto,
    desc: "O que na conversa originou isso (1 frase), para o consultor julgar sem reabrir o chat",
    required: false

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute(categoria:, informacao:, contexto: nil)
    categoria = categoria.to_s.strip
    informacao = informacao.to_s.strip

    unless KnowledgeNote::CATEGORIES.key?(categoria)
      return { error: "Categoria inválida. Use uma de: #{KnowledgeNote::CATEGORIES.keys.join(', ')}." }.to_json
    end
    return { error: "Preciso da informação a ser lembrada." }.to_json if informacao.blank?

    if duplicate?(informacao)
      return { aviso: "Essa informação já foi registrada nesta conversa; não registrei de novo." }.to_json
    end

    note = @conversation.knowledge_notes.create!(
      category: categoria, content: informacao, context: contexto.presence,
      client_name: @conversation.client_name
    )

    {
      success: true, knowledge_note_id: note.id, status: "aguardando aprovação do consultor",
      categoria: note.category_label, informacao: note.content,
      instrucao: "Diga ao consultor o que você propôs guardar e que ele precisa aprovar no card acima."
    }.to_json
  rescue StandardError => e
    Rails.logger.error("RememberForFutureProposalsTool falhou para conversation #{@conversation.id}: #{e.class} #{e.message}")
    { error: "Não consegui registrar essa informação agora." }.to_json
  end

  private

  # A IA repete a mesma proposta de nota quando o assunto volta no chat; sem isso o consultor
  # recebe o mesmo card várias vezes na mesma conversa.
  def duplicate?(informacao)
    @conversation.knowledge_notes.where(content: informacao).exists?
  end
end
