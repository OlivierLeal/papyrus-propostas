require "test_helper"

# Conversa 34 (2026-10): a IA respondeu "Proposta regenerada com sucesso! …Rev.03.docx" sem chamar a
# ferramenta — o Rev.03 nunca existiu. A trava do fim do turno não deixa isso chegar ao consultor.
class DocumentClaimCheckTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:priced_conversation)
  end

  test "anúncio de documento sem arquivo: some, a IA recebe o aviso e responde de novo" do
    @conversation.messages.create!(role: "user", content: "gere novamente a proposta")
    false_claim = "✅ **Proposta regenerada com sucesso!** Arquivo: PTC00001_Cliente_Rev.03.docx"
    honest = "Não gerei ainda — o enquadramento precisa ser confirmado no painel."

    stub_ai_complete([ false_claim, honest ]) { RespondToMessageJob.perform_now(@conversation.id) }

    visible = @conversation.messages.where(role: "assistant", internal: false).pluck(:content)
    assert_not_includes visible, false_claim
    assert_includes visible, honest
    assert @conversation.messages.where(role: "user", internal: true).where("content LIKE ?", "[Aviso automático do sistema]%").exists?
  end

  test "se insistir, o consultor vê um aviso honesto no lugar" do
    @conversation.messages.create!(role: "user", content: "gera a proposta de novo")
    stub_ai_complete("A proposta foi gerada com sucesso.") { RespondToMessageJob.perform_now(@conversation.id) }

    last = @conversation.messages.where(role: "assistant", internal: false).order(:id).last
    assert_equal DocumentClaimCheck::FALLBACK, last.content
    assert last.system_notice
    assert_equal 0, @conversation.messages.where(content: "A proposta foi gerada com sucesso.").count
  end

  test "resposta honesta, pergunta que não pede geração e geração esperando em segundo plano passam intactas" do
    @conversation.messages.create!(role: "user", content: "gere a proposta")
    stub_ai_complete("Não foi gerado: há uma pendência aberta sobre as campanhas.") { RespondToMessageJob.perform_now(@conversation.id) }
    assert_equal "Não foi gerado: há uma pendência aberta sobre as campanhas.", @conversation.messages.where(role: "assistant").order(:id).last.content

    @conversation.messages.create!(role: "user", content: "qual a revisão atual?")
    stub_ai_complete("A versão Rev.07 foi gerada ontem.") { RespondToMessageJob.perform_now(@conversation.id) }
    assert_equal "A versão Rev.07 foi gerada ontem.", @conversation.messages.where(role: "assistant").order(:id).last.content

    @conversation.proposal.update!(pending_generation: { "waiting" => [ "team" ] })
    @conversation.messages.create!(role: "user", content: "gere a proposta")
    stub_ai_complete("Ok, a proposta será gerada assim que a equipe ficar pronta.") { RespondToMessageJob.perform_now(@conversation.id) }
    assert_equal "Ok, a proposta será gerada assim que a equipe ficar pronta.", @conversation.messages.where(role: "assistant").order(:id).last.content
  end

  test "aviso do sistema volta pra IA como aviso, não como fala dela" do
    notice = @conversation.post_system_notice!("Gerado o arquivo PTC00001_Rev.02.docx, disponível na Tela de Precificação.")
    @conversation.messages.create!(role: "user", content: "gere novamente a proposta")

    llm = @conversation.send(:order_messages_for_llm, @conversation.messages.order(:created_at).to_a).map(&:to_llm)
    rewritten = llm.find { |m| m.content.to_s.include?("Rev.02.docx") }

    assert notice.system_notice
    assert_equal :user, rewritten.role
    assert rewritten.content.to_s.start_with?(LlmHistoryTrimming::SYSTEM_NOTICE_PREFIX)
  end
end
