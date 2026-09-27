require "test_helper"

class MessageTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:reviewing_conversation)
  end

  teardown do
    # Current é global (ActiveSupport::CurrentAttributes) — um teste de model que mexe nisso na
    # unha (sem passar pelo ciclo de request/job normal, que reseta sozinho) precisa desfazer, ou
    # vaza pro próximo teste que rodar no mesmo processo.
    Current.session = nil
  end

  # Mais de um consultor pode acompanhar a mesma proposta (ver MessagesController#create) — o
  # chat precisa saber de QUEM é cada mensagem, não só "Você"/"IA". Current.user (setado pela
  # Authentication concern a cada request) é a fonte — ver Message#assign_current_user.
  test "a user-role message created within a request records Current.user automatically" do
    Current.session = users(:one).sessions.create!

    message = @conversation.messages.create!(role: "user", content: "Pergunta qualquer")

    assert_equal users(:one), message.user
  end

  test "an explicitly assigned user is never overwritten by Current.user" do
    Current.session = users(:one).sessions.create!

    message = @conversation.messages.create!(role: "user", content: "Pergunta qualquer", user: users(:two))

    assert_equal users(:two), message.user
  end

  test "a message that is not role user never gets a user, even with Current.user set" do
    Current.session = users(:one).sessions.create!

    message = @conversation.messages.create!(role: "assistant", content: "Resposta da IA")

    assert_nil message.user
  end

  # Mensagens "user" internas do ask_internally (ex.: o snapshot [ESTADO ATUAL DA PROPOSTA]) e o
  # SuggestScheduleJob/ElectScheduleKeyPointsJob rodam em background — nenhum humano "digitou"
  # aquilo, então sem Current.user (fora de um request) a mensagem fica sem usuário, sem quebrar.
  test "a user-role message created outside a request (no Current.user) stays without a user" do
    Current.session = nil

    message = @conversation.messages.create!(role: "user", content: "Instrução interna", internal: true)

    assert_nil message.user
  end

  # Achado ao vivo (conversa 37, 2026-09): a IA quase sempre agrupa mais de um código no MESMO
  # colchete ("[F12, F34]") — cited_findings tem que enxergar cada um, não só o formato de
  # colchete com um código sozinho.
  test "cited_findings resolves every code inside a grouped citation bracket" do
    a = @conversation.project_findings.create!(field: "area_ha", value: "100", nature: "fato", source_kind: "et")
    b = @conversation.project_findings.create!(field: "municipios", value: "Icó/CE", nature: "fato", source_kind: "et")
    message = @conversation.messages.create!(role: "assistant", content: "Área em Icó [F#{a.id}, F#{b.id}].")

    assert_equal [ a, b ].sort_by(&:id), message.cited_findings.sort_by(&:id)
  end

  test "cited_findings ignores a code that doesn't match any active finding, even inside a group" do
    a = @conversation.project_findings.create!(field: "area_ha", value: "100", nature: "fato", source_kind: "et")
    message = @conversation.messages.create!(role: "assistant", content: "Área [F#{a.id}, F999999].")

    assert_equal [ a ], message.cited_findings.to_a
  end

  # Planilha anexada no chat não vai bruta pro provider (ele não lê .xlsx e o turno inteiro
  # falharia) — o texto dela, aba a aba, entra no conteúdo que a IA recebe.
  test "planilha anexada vai como texto no conteúdo pra IA, não como anexo" do
    conversation = conversations(:reviewing_conversation)
    message = conversation.messages.create!(role: "user", content: "segue o edital")
    message.attachments.attach(io: StringIO.new(xlsx_bytes), filename: "edital.xlsx", metadata: { kind: "complementary" })

    llm = message.reload.to_llm

    text = llm.content.is_a?(RubyLLM::Content) ? llm.content.text : llm.content
    assert_includes text, "segue o edital"
    assert_includes text, "## Planilha: Orçamento"
    attachments = llm.content.is_a?(RubyLLM::Content) ? llm.content.attachments : []
    assert_empty attachments
  end

  test "planilha de mensagem antiga não é reenviada (mesma regra dos outros anexos)" do
    conversation = conversations(:reviewing_conversation)
    old = conversation.messages.create!(role: "user", content: "edital")
    old.attachments.attach(io: StringIO.new(xlsx_bytes), filename: "edital.xlsx")
    conversation.messages.create!(role: "user", content: "outra pergunta")

    llm = old.reload.to_llm
    text = llm.content.is_a?(RubyLLM::Content) ? llm.content.text : llm.content

    assert_not_includes text.to_s, "## Planilha"
  end

  # 2026-09-27: anexo que o provider não aceita (antes: UnsupportedAttachmentError derrubava o
  # turno inteiro) vira PDF convertido, texto ou aviso — nunca vai bruto.
  test "anexo não nativo no chat não vai bruto: CAD vira aviso e RTF vira PDF" do
    skip "soffice ausente" unless AttachmentConversions.available?("soffice")

    conversation = conversations(:reviewing_conversation)
    message = conversation.messages.create!(role: "user", content: "seguem os arquivos")
    message.attachments.attach(io: StringIO.new("cad"), filename: "planta.dwg")
    message.attachments.attach(io: StringIO.new("{\\rtf1\\ansi Estrategia}"), filename: "estrategia.rtf")

    content = message.reload.to_llm.content

    assert_includes content.text, "planta.dwg"
    assert_includes content.text, "NÃO deduza"
    assert_equal [ "pdf" ], content.attachments.map { |attachment| File.extname(attachment.filename.to_s).delete(".") }
    assert_nothing_raised { RubyLLM::Providers::Bedrock::Media.render_content(content) }
  end
end
