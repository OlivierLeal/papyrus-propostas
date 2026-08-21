require "test_helper"

# A mensagem do consultor e o indicador de "digitando" precisam viajar num broadcast SÓ.
#
# Quando eram dois broadcast_append_to seguidos, o servidor mandava na ordem certa mas viravam
# duas mensagens de WebSocket independentes — e o Turbo às vezes aplicava a segunda primeiro,
# deixando o indicador ACIMA da mensagem recém-enviada (some com F5, porque aí a página vem
# inteira do servidor). Era intermitente: reproduzia em ~1 de cada 3 execuções.
#
# O teste de sistema (test/system/chat_message_order_test.rb) cobre o resultado visual; este
# cobre o formato do broadcast, que é a causa, e roda em milissegundos.
class ChatBroadcastOrderTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  setup do
    @conversation = conversations(:reviewing_conversation)
    sign_in_as users(:one)
  end

  test "mensagem e indicador vão num único broadcast, nessa ordem" do
    payloads = capture_broadcasts { post_message("gere a proposta tecnica") }

    assert_equal 1, payloads.size, "dois broadcasts separados podem ser aplicados fora de ordem"

    payload = payloads.sole
    assert_equal 2, payload.scan(/<turbo-stream/).size
    assert_operator payload.index("gere a proposta tecnica"), :<, payload.index("typing_indicator"),
      "a mensagem precisa vir antes do indicador dentro do broadcast"
  end

  test "os dois streams são append no container de mensagens" do
    payload = capture_broadcasts { post_message("outra pergunta") }.sole

    assert_equal 2, payload.scan(/action="append"/).size
    assert_equal 2, payload.scan(/target="messages"/).size
  end

  private

  def post_message(content)
    perform_enqueued_jobs(only: []) do
      post conversation_messages_path(@conversation), params: { content: content }
    end
  end

  # O adapter de teste guarda o payload já serializado; sem decodificar, o HTML vem escapado
  # (\u003cturbo-stream) e qualquer busca por tag falha.
  def capture_broadcasts
    stream = Turbo::StreamsChannel.send(:stream_name_from, @conversation)
    before = broadcasts(stream).size
    yield

    broadcasts(stream).drop(before).map { |payload| ActiveSupport::JSON.decode(payload) }
  end
end
