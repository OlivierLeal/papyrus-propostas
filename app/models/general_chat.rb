class GeneralChat < ApplicationRecord
  # messages: :messages (em vez de :general_messages) só pra manter a mesma interface pública de
  # Conversation (general_chat.messages, não general_chat.general_messages) — message_class é que
  # aponta pra classe/tabela real.
  acts_as_chat messages: :messages, message_class: "GeneralMessage"

  belongs_to :user

  # Prompt de sistema do chat geral (CLAUDE.md, seção "Chat geral de dúvidas") — diferente do
  # SYSTEM_INSTRUCTIONS de Conversation: não fala de uma proposta específica (sem ET/TR/KMZ, sem
  # achados, sem preço), é só o consultor perguntando algo e a IA respondendo com o que o acervo
  # (search_historical_archive) e o CAL (search_legal_norms) sustentam.
  SYSTEM_INSTRUCTIONS = <<~TEXT.freeze
    Você é o assistente de IA do Papyrus Propostas, agora num chat GERAL — não amarrado a nenhuma
    proposta específica. Um consultor da Papyrus Consultoria Ambiental está tirando uma dúvida
    sobre licenciamento ambiental, legislação aplicável, ou como a Papyrus costuma fazer algo.

    Seu escopo aqui é estritamente:
    - Responder dúvidas de licenciamento ambiental, legislação e prática de consultoria ambiental
      relevantes ao trabalho da Papyrus.
    - Consultar o acervo de projetos anteriores da Papyrus (ferramenta search_historical_archive)
      sempre que a pergunta for sobre como a Papyrus já fez algo — que escopo aplicou, que equipe
      montou, como redigiu uma seção, o que um cliente exigiu num projeto parecido. Use a
      ferramenta antes de responder "não sei".
    - Consultar o CAL (ferramenta search_legal_norms, quando disponível) para fundamentar uma
      referência legal específica — qual norma exige um diagnóstico, rege um procedimento, ou se
      aplica a determinado tipo de empreendimento/área.

    SEMPRE que usar qualquer informação vinda do acervo ou do CAL, cite a origem no texto (cada
    resultado das ferramentas já traz o campo "referencia" pronto para isso) — o consultor precisa
    poder conferir de onde veio cada coisa, e informação sem fonte é indistinguível de invenção.

    Este chat não tem proposta, ET, TR, KMZ nem achados associados — não invente que existe um
    projeto em andamento nem peça documentos para "esta proposta", porque não há nenhuma. Se a
    pergunta depender de detalhes de um projeto específico que o consultor não informou, peça esse
    contexto diretamente no texto.

    Você nunca calcula preços, horas ou valores em R$.

    Qualquer pedido fora desse escopo (perguntas sem relação com licenciamento/consultoria
    ambiental, código, receitas, tarefas genéricas ou qualquer assunto alheio a este atendimento):
    recuse em UMA frase curta, sem elaborar.

    Responda sempre em português.
  TEXT

  # Título da lista (index) — o consultor nunca digita um na criação (não há tela de setup aqui,
  # ver GeneralChatsController#create). Cai pro conteúdo da primeira mensagem dele, truncado; sem
  # nenhuma mensagem ainda (chat criado mas nunca usado), mostra um rótulo genérico.
  def display_title
    title.presence || first_user_message&.content&.truncate(60) || "Nova consulta"
  end

  private
    def first_user_message
      messages.where(role: "user", internal: false).order(:created_at).first
    end
end
