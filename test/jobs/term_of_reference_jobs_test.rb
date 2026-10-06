require "test_helper"

# TR do estudo achado pelo sistema (2026-10): FindTermOfReferenceJob propõe num card,
# AcceptTermOfReferenceJob busca o arquivo depois que o consultor aceita.
class TermOfReferenceJobsTest < ActiveJob::TestCase
  include CalStubHelper
  include WebSearchStubHelper

  setup do
    @conversation = conversations(:priced_conversation)
    @conversation.study_types << study_types(:eia_rima) unless @conversation.study_types.include?(study_types(:eia_rima))
  end

  test "achou no CAL: cria o candidato pendente e posta o card" do
    reply = { termo_referencia: { fonte: "cal", codigo_norma: "NL555", titulo: "Portaria 1/2020 — TR para EIA/RIMA de eólica", justificativa: "mesmo estudo e atividade" } }

    with_cal_configured { stub_ai_complete(reply.to_json) { FindTermOfReferenceJob.perform_now(@conversation.id) } }

    candidate = @conversation.term_of_reference_candidates.last
    assert candidate.pending?
    assert_equal [ "cal", "NL555" ], [ candidate.source, candidate.norm_code ]
    assert_includes @conversation.messages.where(role: "assistant").pluck(:content), { term_of_reference_candidate_id: candidate.id }.to_json
  end

  test "não procura quando o cliente mandou TR, nem de novo sozinho; pedido no chat avisa quando não acha" do
    @conversation.term_of_reference_candidates.create!(source: "internet", url: "https://orgao.gov.br/tr.pdf", title: "TR", status: "rejected")

    with_cal_configured do
      assert_no_difference -> { @conversation.messages.count } do
        FindTermOfReferenceJob.perform_now(@conversation.id) # automático: já houve candidato, não insiste
      end
      stub_ai_complete({ termo_referencia: { fonte: "internet", url: "https://orgao.gov.br/tr.pdf", titulo: "TR" } }.to_json) do
        FindTermOfReferenceJob.perform_now(@conversation.id, force: true)
      end
    end

    assert_equal 1, @conversation.term_of_reference_candidates.count, "o descartado não volta"
    assert_match "não encontrei", @conversation.messages.where(role: "assistant").last.content

    message = @conversation.messages.create!(role: "user", content: "setup")
    message.attachments.attach(io: StringIO.new("%PDF-1.4"), filename: "TR.pdf", metadata: { kind: "tr" })
    with_cal_configured do
      assert_no_difference -> { @conversation.messages.count } do
        FindTermOfReferenceJob.perform_now(@conversation.id, force: true)
      end
    end
  end

  test "aceitar um TR da internet baixa o arquivo, vira o TR da conversa e manda ler" do
    candidate = @conversation.term_of_reference_candidates.create!(source: "internet", url: "https://orgao.gov.br/tr.pdf", title: "TR", status: "accepting")
    download = TermOfReferenceAnnex::Downloader::Result.new(io: StringIO.new("%PDF-1.4 tr"), filename: "tr.pdf", content_type: "application/pdf")

    with_downloader(->(_url) { download }) do
      assert_enqueued_with(job: ProcessTrJob, args: [ @conversation.id ]) { AcceptTermOfReferenceJob.perform_now(candidate.id) }
    end

    assert candidate.reload.accepted?
    assert_equal [ "tr.pdf" ], @conversation.term_of_reference_attachments.map { |a| a.filename.to_s }
  end

  test "falha ao baixar fica registrada no card, e o TR do cliente sempre vence o aceito" do
    candidate = @conversation.term_of_reference_candidates.create!(source: "internet", url: "https://orgao.gov.br/tr.pdf", title: "TR", status: "accepting")
    with_downloader(->(_url) { raise TermOfReferenceAnnex::Downloader::Error, "O link não é um PDF nem um arquivo do Word." }) do
      AcceptTermOfReferenceJob.perform_now(candidate.id)
    end
    assert candidate.reload.failed?
    assert_equal "O link não é um PDF nem um arquivo do Word.", candidate.error

    candidate.file.attach(io: StringIO.new("%PDF"), filename: "achado.pdf")
    candidate.update!(status: "accepted")
    message = @conversation.messages.create!(role: "user", content: "setup")
    message.attachments.attach(io: StringIO.new("%PDF"), filename: "do_cliente.pdf", metadata: { kind: "tr" })
    assert_equal [ "do_cliente.pdf" ], @conversation.term_of_reference_attachments.map { |a| a.filename.to_s }
  end

  private

  def with_downloader(fake)
    original = TermOfReferenceAnnex::Downloader.method(:call)
    TermOfReferenceAnnex::Downloader.define_singleton_method(:call) { |url| fake.call(url) }
    yield
  ensure
    TermOfReferenceAnnex::Downloader.define_singleton_method(:call, original)
  end
end
