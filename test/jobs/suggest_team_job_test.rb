require "test_helper"

class SuggestTeamJobTest < ActiveJob::TestCase
  test "fills the team when the proposal only has always_included lines and no study_templates" do
    conversation = Conversation.create!(user: users(:one), client_name: "Sem Templates", status: "reviewing", study_types: [ study_types(:rap) ])
    proposal = conversation.create_proposal!(status: "draft")
    proposal.build_from_template!
    ai_response = {
      linhas: [ { professional_id: professionals(:biologa).id, deliverable_name: "Diagnóstico de Fauna e Flora", hours_office: 40, hours_field: 24 } ],
      documentos_separados: false
    }.to_json

    stub_ai_complete(ai_response) { SuggestTeamJob.new.perform(proposal.id) }

    assert proposal.project_pricing.reload.proposal_professionals.exists?(professional: professionals(:biologa))
  end

  test "does nothing when the team already has a non-always_included line (idempotente)" do
    proposal = proposals(:priced_proposal) # já tem coordenador + biologa cadastrados na fixture

    assert_no_ai_calls { SuggestTeamJob.new.perform(proposal.id) }
  end

  test "does nothing for a study type with study_templates (eia_rima)" do
    proposal = conversations(:reviewing_conversation).create_proposal!(status: "draft")
    proposal.build_from_template!

    assert_no_ai_calls { SuggestTeamJob.new.perform(proposal.id) }
  end

  test "does nothing when the proposal has no pricing" do
    proposal = conversations(:reviewing_conversation).create_proposal!(status: "draft", version: 1)

    assert_nothing_raised { SuggestTeamJob.new.perform(proposal.id) }
  end

  test "does not raise when the proposal id does not exist" do
    assert_nothing_raised { SuggestTeamJob.new.perform(-1) }
  end

  test "logs and swallows the error instead of raising when the AI call fails" do
    conversation = Conversation.create!(user: users(:one), client_name: "Sem Templates", status: "reviewing", study_types: [ study_types(:rap) ])
    proposal = conversation.create_proposal!(status: "draft")
    proposal.build_from_template!

    assert_nothing_raised do
      stub_ai_error { SuggestTeamJob.new.perform(proposal.id) }
    end
    assert_not proposal.project_pricing.reload.proposal_professionals.joins(:professional).where(professionals: { always_included: false }).exists?
  end

  # Relato do consultor: gerar sem a equipe e pedir "gere de novo" era ruim — o job agora termina
  # sozinho, remontando o .docx com a equipe incluída (CLAUDE.md seção 8).
  test "auto-regenerates the docx when a document was already generated without the team" do
    conversation = Conversation.create!(user: users(:one), client_name: "Sem Templates", status: "reviewing", study_types: [ study_types(:rap) ])
    proposal = conversation.create_proposal!(status: "draft")
    proposal.build_from_template!
    proposal.generated_documents.attach(
      io: StringIO.new("v1"), filename: "v1.docx", content_type: "application/octet-stream",
      metadata: { kind: "tecnica", version: 1, description: "Emissão Inicial" }
    )
    proposal.update!(content_json: {
      nome_cliente: "A confirmar", contato_cliente: "A confirmar", descricao_servico: "RAP",
      municipios: "Correntina", estado: "BA", cnpj_cliente: "A confirmar",
      objetivo_dos_servicos: "Elaborar o RAP.", caracterizacao_do_empreendimento: "PCH.",
      nome_documento_tr: "ET", escopo_e_metodologia: "Escopo.", prazo_de_execucao: "90 dias",
      produtos: [ "RAP" ], descricao_revisao: "Emissão Inicial"
    })
    ai_response = { linhas: [ { professional_id: professionals(:biologa).id, deliverable_name: "Diagnóstico de Fauna e Flora", hours_office: 40, hours_field: 24 } ], documentos_separados: false }.to_json
    version_before = proposal.version

    stub_ai_complete(ai_response) { SuggestTeamJob.new.perform(proposal.id) }

    assert_operator proposal.reload.version, :>, version_before
    assert_equal "assistant", conversation.messages.order(:created_at).last.role
  end
end
