require "test_helper"

class RememberForFutureProposalsToolTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:reviewing_conversation)
    @tool = RememberForFutureProposalsTool.new(conversation: @conversation)
  end

  test "cria a nota como pendente, nunca já valendo" do
    result = call(categoria: "preferencia_cliente", informacao: "Cliente exige proposta em duas partes")

    note = @conversation.knowledge_notes.sole
    assert result["success"]
    assert_equal note.id, result["knowledge_note_id"]
    assert note.pending?, "a ferramenta propõe, quem aprova é o consultor"
    assert_not KnowledgeNote.searchable.exists?(id: note.id)
  end

  test "herda o cliente da conversa para a memória ser reencontrável" do
    call(categoria: "condicionante_orgao", informacao: "INEMA exige inventário florestal")

    assert_equal @conversation.client_name, @conversation.knowledge_notes.sole.client_name
  end

  test "categoria fora do menu é recusada sem criar nada" do
    result = call(categoria: "coisa_inventada", informacao: "algo")

    assert result["error"].present?
    assert_empty @conversation.knowledge_notes
  end

  test "informação vazia é recusada" do
    result = call(categoria: "preferencia_cliente", informacao: "   ")

    assert result["error"].present?
    assert_empty @conversation.knowledge_notes
  end

  test "não registra a mesma informação duas vezes na mesma conversa" do
    2.times { call(categoria: "preferencia_cliente", informacao: "Cliente exige NDA assinado") }

    assert_equal 1, @conversation.knowledge_notes.count, "o consultor não pode receber o mesmo card repetido"
  end

  test "guarda o contexto para o consultor julgar sem reabrir o chat" do
    call(categoria: "escopo_metodologia", informacao: "Usar transectos de 500m",
         contexto: "Consultor corrigiu a metodologia proposta")

    assert_equal "Consultor corrigiu a metodologia proposta", @conversation.knowledge_notes.sole.context
  end

  # Achado ao vivo nesta sessão: o resultado bruto de uma tool call nasce como mensagem role
  # "tool", que Message#hide_tool_result! sempre esconde — sem uma mensagem PRÓPRIA (role
  # assistant) só pro card, o "Guardar"/"Descartar" nunca chegava a aparecer no chat de verdade.
  test "cria uma mensagem assistant visível, própria pro card de aprovação" do
    call(categoria: "preferencia_cliente", informacao: "Cliente exige proposta em duas partes")

    note = @conversation.knowledge_notes.sole
    card_message = @conversation.messages.where(role: "assistant", internal: false).order(:created_at).last
    assert_equal({ "knowledge_note_id" => note.id }, JSON.parse(card_message.content))
  end

  test "funciona também a partir de um general_chat, sem conversation nenhuma" do
    general_chat = general_chats(:with_messages)
    tool = RememberForFutureProposalsTool.new(general_chat: general_chat)

    result = JSON.parse(tool.execute(categoria: "escopo_metodologia", informacao: "Regra geral da Papyrus"))

    note = general_chat.knowledge_notes.sole
    assert result["success"]
    assert_equal note.id, result["knowledge_note_id"]
    assert_nil note.conversation
    assert_equal general_chat, note.general_chat
  end

  test "no general_chat, sem cliente informado a nota fica sem client_name" do
    general_chat = general_chats(:with_messages)
    tool = RememberForFutureProposalsTool.new(general_chat: general_chat)

    tool.execute(categoria: "escopo_metodologia", informacao: "Regra geral da Papyrus")

    assert_nil general_chat.knowledge_notes.sole.client_name
  end

  test "no general_chat, o parâmetro cliente vira o client_name da nota" do
    general_chat = general_chats(:with_messages)
    tool = RememberForFutureProposalsTool.new(general_chat: general_chat)

    tool.execute(categoria: "preferencia_cliente", informacao: "Sempre exige ART em anexo", cliente: "Petrobras")

    assert_equal "Petrobras", general_chat.knowledge_notes.sole.client_name
  end

  test "dentro de uma conversation, o parâmetro cliente é ignorado — o cliente já é um fato do sistema" do
    call(categoria: "preferencia_cliente", informacao: "Cliente exige proposta em duas partes", cliente: "Nome Errado")

    assert_equal @conversation.client_name, @conversation.knowledge_notes.sole.client_name
  end

  private

  def call(**args) = JSON.parse(@tool.execute(**args))
end
