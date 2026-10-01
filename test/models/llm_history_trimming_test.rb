require "test_helper"

class LlmHistoryTrimmingTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:reviewing_conversation)
    @t = 1.minute.from_now
    @seq = 0
  end

  def add(role, content, internal: false, **attrs)
    @seq += 1
    @conversation.messages.create!(role: role, content: content, internal: internal, created_at: @t + @seq, **attrs)
  end

  def add_tool_exchange(result, internal_call: false)
    call = add("assistant", nil, internal: internal_call)
    tool_call = call.tool_calls.create!(tool_call_id: "toolu_#{@seq}", name: "search_legal_norms", arguments: {})
    add("tool", result, internal: true, tool_call_id: tool_call.id)
  end

  def llm_texts
    @conversation.reload.to_llm.messages.map do |message|
      content = message.content
      content.is_a?(RubyLLM::Content::Raw) ? content.value.to_json : (content.respond_to?(:text) ? content.text : content).to_s
    end
  end

  test "troca interna antiga sai do histórico; a resposta visível dela fica, com marcador no lugar do pedido" do
    add("user", "Pesquise no CAL a legislação aplicável", internal: true)
    add_tool_exchange("TEXTO COMPLETO DA LC 140 " * 50)
    add("assistant", '{"achados":[]}', internal: true)
    add("user", "Monte um resumo estruturado para o consultor", internal: true)
    add("assistant", "## Resumo da proposta")
    add("user", "gere a proposta")

    texts = llm_texts
    assert texts.none? { |t| t.include?("Pesquise no CAL") || t.include?("LC 140") || t.include?("achados") }
    assert texts.any? { |t| t.include?("pedido omitido do histórico: Monte um resumo estruturado") }
    assert texts.any? { |t| t.include?("## Resumo da proposta") }
    assert_equal "gere a proposta", texts.last
  end

  test "o turno atual vai inteiro, mesmo quando é um pedido interno (ask_internally)" do
    add("user", "oi")
    add("assistant", "olá")
    add("user", "Você monta a composição de equipe", internal: true)
    add_tool_exchange("RESULTADO LONGO DO ACERVO " * 100)

    texts = llm_texts
    assert_includes texts, "Você monta a composição de equipe"
    assert texts.any? { |t| t.start_with?("RESULTADO LONGO DO ACERVO") && t.size > LlmHistoryTrimming::TOOL_RESULT_KEEP }
  end

  test "resultado longo de ferramenta de turno anterior vira referência curta, sem quebrar o par chamada/resultado" do
    add("user", "busque no acervo")
    add_tool_exchange("RESULTADO LONGO DO ACERVO " * 100)
    add("assistant", "Achei o projeto 25001.")
    add("user", "e agora?")

    messages = @conversation.reload.to_llm.messages
    result = messages.find(&:tool_call_id)
    assert_includes result.content.to_s, "omitido do histórico"
    call_index = messages.index { |m| m.tool_calls.present? }
    assert_equal result, messages[call_index + 1]
  end

  test "marca o ponto de cache no último texto simples do histórico anterior, nunca no snapshot" do
    add("user", "primeira pergunta")
    add("assistant", "primeira resposta")
    add("user", "#{Conversation::PROPOSAL_STATE_MARKER} estado")
    add("user", "segunda pergunta")

    cached = @conversation.reload.to_llm.messages.select { |m| m.content.is_a?(RubyLLM::Content::Raw) && m.content.value.to_json.include?("cachePoint") }
    texts = cached.map { |m| m.content.value.first[:text] }
    assert_includes texts, "primeira resposta"
    assert texts.none? { |t| t.to_s.start_with?(Conversation::PROPOSAL_STATE_MARKER) }
  end

  test "resposta interna com texto corrido fica resumida; a que é só JSON sai" do
    add("user", "TAREFA: preencha a planilha DFP", internal: true)
    add("assistant", "O problema é claro: a fórmula M3 usa a coluna errada.\n```json\n{\"celulas\":[]}\n```", internal: true)
    add("user", "Analise o complementar", internal: true)
    add("assistant", '{"achados":[{"campo":"outro"}]}', internal: true)
    add("user", "o que deu errado na DFP?")

    texts = llm_texts
    assert texts.any? { |t| t.include?("[Resposta da tarefa interna, resumida] O problema é claro: a fórmula M3") }
    assert texts.none? { |t| t.include?("celulas") || t.include?("achados") || t.include?("Analise o complementar") }
  end

  test "toda tarefa interna declara as mesmas ferramentas de leitura, na mesma ordem (prefixo de cache igual)" do
    declared = []
    original = Conversation.instance_method(:complete)
    Conversation.define_method(:complete) do
      declared << to_llm.tools.keys
      messages.create!(role: "assistant", content: "{}")
    end
    with_cal_configured do
      @conversation.ask_internally("extração", hide_response: true)
      Conversation.find(@conversation.id).ask_internally("equipe", hide_response: true, tools: true)
    end

    assert_equal 2, declared.size
    assert_equal declared.first, declared.last
    assert_includes declared.first, :search_legal_norms
    assert_not declared.first.intersect?(%i[generate_proposal_document add_external_cost])
    extraction, team = @conversation.messages.where(internal: true, role: "user").where("content LIKE ? OR content LIKE ?", "extração%", "equipe%").order(:id).pluck(:content)
    assert_includes extraction, Conversation::INTERNAL_NO_TOOLS_NOTE
    assert_not_includes team, Conversation::INTERNAL_NO_TOOLS_NOTE
  ensure
    Conversation.define_method(:complete, original)
  end
end
