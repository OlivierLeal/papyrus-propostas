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

  private

  def call(**args) = JSON.parse(@tool.execute(**args))
end
