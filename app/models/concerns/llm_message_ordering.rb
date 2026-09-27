# Ordem do histórico que vai pra IA: cada chamada de ferramenta (mensagem assistant com
# tool_calls) é SEMPRE seguida imediatamente dos seus resultados (role "tool") — o Bedrock recusa
# o turno inteiro se qualquer outra mensagem estiver no meio ("tool_use ids were found without
# tool_result blocks immediately after").
#
# Por que pode ter algo no meio (2026-09-27, cenário do consultor: "peço a proposta técnica e,
# enquanto gera, mando mensagem pedindo de novo"): o ruby_llm monta o histórico pela ORDEM DE
# CRIAÇÃO. A mensagem do consultor é gravada na hora; a chamada da ferramenta já tinha sido
# gravada e o resultado só é gravado quando a ferramenta termina (a geração do .docx leva
# segundos) — a mensagem dele cai ENTRE os dois. O turno em andamento termina bem (a gem guarda a
# sequência em memória), mas todo turno seguinte relia o histórico nessa ordem e falhava: a
# conversa travava pra sempre. Reordenar aqui cura também conversa que já ficou nesse estado.
module LlmMessageOrdering
  extend ActiveSupport::Concern

  private
    def order_messages_for_llm(messages)
      ordered = super
      call_ids_by_message = tool_call_ids_by_message(ordered.map(&:id))
      results_by_call = ordered.select { |message| message.role.to_s == "tool" }.group_by { |message| tool_result_call_id(message) }
      moved = Set.new

      ordered.each_with_object([]) do |message, output|
        next if moved.include?(message.id)

        output << message
        Array(call_ids_by_message[message.id]).each do |call_id|
          Array(results_by_call[call_id]).each do |result|
            output << result
            moved << result.id
          end
        end
      end
    end
end
