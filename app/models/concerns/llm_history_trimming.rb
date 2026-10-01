# Histórico enxuto pra IA (2026-10, custo: ~85% da fatura do Bedrock era token de ENTRADA, com
# chamadas de 160-250 mil tokens numa conversa só).
#
# Cada `ask_internally` (análise do ET/TR/complementares, CAL, resumo, equipe, cronograma, planilhas)
# grava pedido + resposta na conversa, e toda chamada seguinte reenviava tudo isso: o texto
# completo de normas lidas no CAL, o pedido de 67 mil caracteres do resumo, o plano da DFP... O
# RESULTADO dessas tarefas já mora em dado estruturado (achados, precificação, planilhas) e chega
# pelo snapshot `[ESTADO ATUAL DA PROPOSTA]`, então a transcrição que o produziu é redundante.
#
# O que muda, só nos turnos ANTERIORES (o turno atual vai sempre inteiro — é ele que a IA está
# respondendo, inclusive as voltas de ferramenta em andamento):
# - troca interna (abre com um pedido de ask_internally): saem o pedido, as chamadas de
#   ferramenta e os resultados. A resposta VISÍVEL ao consultor (o resumo do GenerateSummaryJob, um
#   card) fica; a resposta interna fica só se tiver texto corrido, resumida em 500 caracteres (JSON
#   puro sai — ver #internal_prose_summary). Um marcador curto entra no lugar do pedido;
# - resultado de ferramenta com mais de TOOL_RESULT_KEEP caracteres vira uma referência curta (a IA
#   chama a ferramenta de novo se precisar — a legislação lida está guardada em LegalNorm);
# - mensagens do consultor, respostas do chat e o snapshot ficam.
#
# Medido antes de ligar (script/ai_cost/compare_context.rb, conversas 65/63/31, 15 casos, juiz +
# controle rodando o histórico completo duas vezes): entrada −75%, e a diferença de qualidade ficou
# dentro da variação do próprio modelo (controle: 5 de 15 "pior"; enxuto: 4 de 15). O que se perdia
# no 1º teste (revisão atual do documento, pendências das planilhas) só existia nas trocas internas
# — foi pro snapshot. Dado que o chat precise depois vai pro snapshot; texto corrido de uma
# resposta interna fica resumido como rede de segurança, mas sem garantia de estar completo.
#
# Também marca o 2º ponto de cache do Bedrock no fim do histórico anterior (o 1º é o fim do prompt
# de sistema, Conversation#mark_system_instructions_cacheable!): as voltas de ferramenta do mesmo
# turno e o turno seguinte dentro de ~5 min leem esse prefixo a 10% do preço.
module LlmHistoryTrimming
  extend ActiveSupport::Concern

  TOOL_RESULT_KEEP = 1500
  INTERNAL_PROSE_KEEP = 500

  # O ruby_llm só chama #to_llm em cada item da lista — pra mensagem reescrita aqui basta isso.
  Rewritten = Data.define(:llm) do
    def to_llm = llm
  end

  private
    def order_messages_for_llm(messages)
      # O ruby_llm lê anexos e chamadas de ferramenta mensagem a mensagem (Message#to_llm) — N+1.
      ActiveRecord::Associations::Preloader.new(records: messages, associations: [ { attachments_attachments: :blob }, :tool_calls, :parent_tool_call, :model ]).call
      ordered = super
      segments = llm_history_segments(ordered)
      return ordered if segments.size <= 1

      current = segments.pop
      call_ids = tool_call_ids_by_message(ordered.select { |m| m.role.to_s == "assistant" }.map(&:id))
      past = segments.flat_map { |segment| trimmed_llm_segment(segment, call_ids) }
      with_history_cache_point(past, call_ids) + current[:messages]
    end

    # Segmento = de uma mensagem de usuário até a próxima. O snapshot não abre segmento (faz parte
    # do turno em que foi gerado); um pedido interno abre um segmento interno.
    def llm_history_segments(ordered)
      ordered.each_with_object([]) do |message, list|
        opens = message.role.to_s == "user" && !llm_snapshot?(message)
        list << { internal: opens && message.internal, messages: [] } if opens || list.empty?
        list.last[:messages] << message
      end
    end

    def trimmed_llm_segment(segment, call_ids)
      return segment[:messages].map { |m| shortened_tool_result(m) } unless segment[:internal]

      opener, *rest = segment[:messages]
      kept = rest.filter_map do |m|
        next m if llm_snapshot?(m)
        next unless m.role.to_s == "assistant" && m.content.present? && call_ids[m.id].blank?
        next m unless m.internal

        internal_prose_summary(m.content)
      end
      return kept if kept.all? { |m| m.is_a?(ActiveRecord::Base) && llm_snapshot?(m) }

      title = opener.content.to_s.lines.first.to_s.strip.truncate(160)
      [ Rewritten.new(RubyLLM::Message.new(role: :user, content: "[Tarefa interna do sistema, pedido omitido do histórico: #{title}]")), *kept ]
    end

    # Rede de segurança: a resposta interna que é só JSON sai (o dado já foi gravado em tabela —
    # achados, plano, equipe — e chega pelo snapshot), mas a que tem TEXTO corrido (diagnóstico,
    # correção, "a fórmula M3 usa a coluna errada") fica resumida. Sem isso, o que um job novo
    # explicasse só em texto sumiria do chat no turno seguinte.
    def internal_prose_summary(content)
      prose = content.to_s.split(/```|^\s*[{\[]/, 2).first.to_s.strip
      return if prose.blank?

      Rewritten.new(RubyLLM::Message.new(role: :assistant, content: "[Resposta da tarefa interna, resumida] #{prose.truncate(INTERNAL_PROSE_KEEP)}"))
    end

    def shortened_tool_result(message)
      return message unless message.role.to_s == "tool" && message.content.to_s.size > TOOL_RESULT_KEEP

      text = message.content.to_s
      Rewritten.new(RubyLLM::Message.new(
        role: :tool, tool_call_id: message.to_llm.tool_call_id,
        content: "[Resultado de ferramenta omitido do histórico (#{text.size} caracteres) para economizar contexto. " \
                 "Se precisar do conteúdo, chame a ferramenta de novo.] Início: #{text[0, 300]}"
      ))
    end

    # Último texto simples do histórico anterior (sem chamada de ferramenta, sem anexo, sem
    # snapshot — o snapshot muda a cada turno e invalidaria o prefixo).
    def with_history_cache_point(past, call_ids)
      index = past.rindex do |m|
        m.is_a?(ActiveRecord::Base) && %w[user assistant].include?(m.role.to_s) && !llm_snapshot?(m) &&
          call_ids[m.id].blank? && m.content_raw.blank? && m.content.present? && !m.attachments.attached?
      end
      return past unless index

      message = past[index]
      past.dup.tap do |list|
        list[index] = Rewritten.new(RubyLLM::Message.new(
          role: message.role.to_sym,
          content: RubyLLM::Content::Raw.new([ { text: message.content }, { cachePoint: { type: "default" } } ])
        ))
      end
    end

    def llm_snapshot?(message)
      message.role.to_s == "user" && message.content.to_s.start_with?(Conversation::PROPOSAL_STATE_MARKER)
    end
end
