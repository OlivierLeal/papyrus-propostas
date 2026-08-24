require "test_helper"

class MessageTest < ActiveSupport::TestCase
  # Achado num caso real em produção: o resultado bruto de uma tool call (ex.: SearchHistorical
  # ArchiveTool) aparecia como uma bolha própria de JSON no chat, porque a mensagem role "tool"
  # nasce internal: false por padrão e cai no fallback genérico de _message.html.erb.
  test "a message with role tool is automatically hidden from the visible chat" do
    conversation = conversations(:reviewing_conversation)
    message = conversation.messages.create!(role: "tool", content: '{"resultados": []}')

    assert message.internal?
  end

  test "a message with role user or assistant is not hidden just for existing" do
    conversation = conversations(:reviewing_conversation)
    user_message = conversation.messages.create!(role: "user", content: "oi")
    assistant_message = conversation.messages.create!(role: "assistant", content: "olá")

    assert_not user_message.internal?
    assert_not assistant_message.internal?
  end

  test "to_llm content excludes kmz attachments (geoespacial, a IA não lê)" do
    message = messages(:reviewing_setup_message)
    message.attachments.attach(
      io: StringIO.new("conteúdo kmz"), filename: "area.kmz", content_type: "application/vnd.google-earth.kmz",
      metadata: { kind: "kmz" }
    )
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "tr.pdf", content_type: "application/pdf",
      metadata: { kind: "tr" }
    )

    llm_message = message.to_llm

    attached_filenames = llm_message.content.attachments.map(&:filename)
    assert_includes attached_filenames, "tr.pdf"
    assert_not_includes attached_filenames, "area.kmz"
  end

  test "to_llm content includes every attachment when there is no kmz" do
    message = messages(:reviewing_setup_message)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "tr.pdf", content_type: "application/pdf",
      metadata: { kind: "tr" }
    )

    llm_message = message.to_llm

    assert_equal [ "tr.pdf" ], llm_message.content.attachments.map(&:filename)
  end

  # Achado num caso real em produção: a Anthropic recusa qualquer request com mais de 5
  # documentos no total, e o ruby_llm reenvia o histórico inteiro em toda chamada (Chat#to_llm) —
  # sem isso, uma conversa com TR + vários complementares quebra pra sempre depois do 5º
  # documento analisado, inclusive o resumo e o chat normal.
  test "to_llm content excludes attachments from any user message that isn't the most recent one" do
    conversation = conversations(:reviewing_conversation)
    setup_message = messages(:reviewing_setup_message)
    setup_message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "tr.pdf", content_type: "application/pdf", metadata: { kind: "tr" }
    )

    later_instruction = conversation.messages.create!(role: "user", content: "instrução interna", internal: true)
    later_instruction.attachments.attach(
      io: StringIO.new("conteúdo do complementar"), filename: "comp.pdf", content_type: "application/pdf",
      metadata: { kind: "complementary" }
    )

    # Sem anexo nenhum sobrando, RubyLLM::Message#content simplifica pra String pura em vez de um
    # RubyLLM::Content (ver ruby_llm/message.rb) — é assim que confirmamos que nada foi enviado.
    assert_equal "Arquivos enviados para análise — TR: tr.pdf.", setup_message.to_llm.content
    assert_equal [ "comp.pdf" ], later_instruction.to_llm.content.attachments.map(&:filename)
  end

  test "to_llm content keeps the attachment on the most recent user message even when it's the original setup message" do
    message = messages(:reviewing_setup_message)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "tr.pdf", content_type: "application/pdf", metadata: { kind: "tr" }
    )

    assert_equal [ "tr.pdf" ], message.to_llm.content.attachments.map(&:filename)
  end

  test "stale attachments stay fully downloadable — only what's sent to the AI changes" do
    conversation = conversations(:reviewing_conversation)
    setup_message = messages(:reviewing_setup_message)
    setup_message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "tr.pdf", content_type: "application/pdf", metadata: { kind: "tr" }
    )
    conversation.messages.create!(role: "user", content: "instrução interna", internal: true)
      .attachments.attach(io: StringIO.new("x"), filename: "comp.pdf", content_type: "application/pdf")

    assert_not_instance_of RubyLLM::Content, setup_message.to_llm.content # nada enviado pra IA
    assert setup_message.reload.attachments.attached?
    assert_equal "tr.pdf", setup_message.attachments.first.filename.to_s
  end


  # REGRESSÃO (visto em uso): o consultor anexa um documento no chat e escreve junto, e a IA
  # responde como se só houvesse o texto. O anexo chega ao banco e aparece na barra lateral, mas
  # nunca é enviado ao modelo — porque RespondToMessageJob grava o snapshot do estado da proposta
  # ANTES de chamar a IA, e esse snapshot é uma mensagem de usuário criada DEPOIS da do consultor.
  # A dele deixa de ser "a mais recente" e perde o anexo na hora de montar o histórico.
  test "to_llm keeps the attachment of the consultant's message even after the state snapshot is written" do
    conversation = conversations(:reviewing_conversation)
    mensagem = conversation.messages.create!(role: "user", content: "segue o projeto básico, analise")
    mensagem.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "projeto_basico.pdf",
      content_type: "application/pdf", metadata: { kind: "complementary" }
    )

    conversation.refresh_proposal_state_snapshot!

    assert_equal [ "projeto_basico.pdf" ], mensagem.reload.to_llm.content.attachments.map(&:filename)
  end

  # O snapshot em si nunca tem anexo, então ele não pode "roubar" a vez de ninguém.
  test "the state snapshot never carries attachments of its own" do
    conversation = conversations(:reviewing_conversation)
    conversation.refresh_proposal_state_snapshot!

    snapshot = conversation.messages.where(role: "user", internal: true).last
    assert_not snapshot.attachments.attached?
  end
end
