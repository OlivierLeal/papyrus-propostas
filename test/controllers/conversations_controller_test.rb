require "test_helper"

class ConversationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as @user
  end

  test "index lists conversations for a signed-in user" do
    get conversations_path
    assert_response :success
  end

  test "index filters by the q param and shows it back in the search field" do
    get conversations_path, params: { q: "Serra Verde" }

    assert_response :success
    assert_match conversations(:reviewing_conversation).client_name, response.body
    assert_no_match conversations(:priced_conversation).client_name, response.body
    assert_select "input[name=?][value=?]", "q", "Serra Verde"
  end

  test "index shows a specific empty-state message when the search matches nothing" do
    get conversations_path, params: { q: "nome que não existe de jeito nenhum" }

    assert_response :success
    assert_match "Nenhuma proposta encontrada", response.body
  end

  # A numeração da proposta reinicia todo ano (Proposal#docx_numero_proposta carrega o ano de 2
  # dígitos) — pedido do consultor pra deixar isso visível na tela conforme o uso do sistema
  # acumula mais de um ano de histórico, já que o mesmo id volta a aparecer em anos diferentes.
  test "index groups conversations into current year, previous year, and older, in that order" do
    atual = Conversation.create!(user: @user, client_name: "Cliente Deste Ano", status: "setup")
    ano_passado = Conversation.create!(user: @user, client_name: "Cliente Do Ano Passado", status: "setup")
    ano_passado.update_column(:created_at, 1.year.ago)
    antigo = Conversation.create!(user: @user, client_name: "Cliente Bem Antigo", status: "setup")
    antigo.update_column(:created_at, 3.years.ago)

    get conversations_path

    assert_response :success
    ano_atual_label = Date.current.year.to_s
    ano_passado_label = (Date.current.year - 1).to_s

    assert_match ano_atual_label, response.body
    assert_match ano_passado_label, response.body
    assert_match "Anteriores", response.body

    # Ordem das seções: ano atual primeiro, depois o anterior, depois "Anteriores" — e cada
    # conversa cai na seção certa (index() da label bate antes do index() do cliente da seção
    # seguinte, mesma técnica já usada neste arquivo pra checar ordem de versões).
    assert_operator response.body.index(ano_atual_label), :<, response.body.index(atual.client_name)
    assert_operator response.body.index(atual.client_name), :<, response.body.index(ano_passado_label)
    assert_operator response.body.index(ano_passado_label), :<, response.body.index(ano_passado.client_name)
    assert_operator response.body.index(ano_passado.client_name), :<, response.body.index("Anteriores")
    assert_operator response.body.index("Anteriores"), :<, response.body.index(antigo.client_name)
  end

  test "index does not show a year section that has no conversations" do
    ano_passado = Conversation.create!(user: @user, client_name: "Único Cliente do Ano Passado", status: "setup")
    ano_passado.update_column(:created_at, 1.year.ago)
    Conversation.where.not(id: ano_passado.id).destroy_all

    get conversations_path

    assert_response :success
    assert_no_match "Anteriores", response.body
  end

  test "index redirects a guest to the login screen" do
    sign_out
    get conversations_path
    assert_redirected_to new_session_path
  end

  test "authenticated? reflects whether the request resumed a session" do
    get conversations_path
    assert @controller.send(:authenticated?)
  end

  test "new renders the setup form" do
    get new_conversation_path
    assert_response :success
  end

  # ProcessTrJob NÃO é um dos jobs disparados aqui — TR só entra depois que ET (e a pesquisa no
  # CAL entre os dois, quando ela roda) terminam, ver ProcessEtJob#advance_after_et! e
  # ProcessLegalNormsJob. Testado à parte, no fluxo de encadeamento de cada job.
  test "create persists the conversation, applies system instructions and enqueues all processing jobs" do
    et = fixture_file_upload("tr_sample.pdf", "application/pdf")
    tr = fixture_file_upload("tr_sample.pdf", "application/pdf")
    kmz = fixture_file_upload("area_sample.kmz", "application/vnd.google-earth.kmz")

    assert_enqueued_with(job: ProcessEtJob) do
      assert_enqueued_with(job: ProcessCompDocsJob) do
        assert_enqueued_with(job: ProcessKmzJob) do
          assert_no_enqueued_jobs(only: ProcessTrJob) do
            assert_difference "Conversation.count", 1 do
              post conversations_path, params: {
                conversation: { client_name: "Cliente Novo" },
                et: et, tr: tr, kmz: kmz, complementary_documents: [ fixture_file_upload("comp_sample.pdf", "application/pdf") ]
              }
            end
          end
        end
      end
    end

    conversation = Conversation.order(:created_at).last
    assert_redirected_to conversation
    assert_equal "processing", conversation.status
    assert_equal @user, conversation.user
    assert conversation.messages.where(role: "system").exists?
  end

  test "create marks cal as pending when there's an ET and the CAL is configured, skipped otherwise" do
    et = fixture_file_upload("tr_sample.pdf", "application/pdf")

    with_cal_configured do
      post conversations_path, params: { conversation: { client_name: "Com CAL" }, et: et }
    end
    assert_equal "pending", Conversation.order(:created_at).last.processing_step_status("cal")

    without_cal_configured do
      post conversations_path, params: { conversation: { client_name: "Sem CAL" }, et: et }
    end
    assert_equal "skipped", Conversation.order(:created_at).last.processing_step_status("cal")
  end

  test "create never sets study_type — it's identified later by ProcessEtJob, not chosen at setup" do
    post conversations_path, params: {
      conversation: { client_name: "Cliente Novo" }
    }

    conversation = Conversation.order(:created_at).last
    assert_nil conversation.study_type_id # study_type_id nos params é ignorado — não é mais permitido
  end

  test "create works with no attachments at all (et, tr, comp_docs and kmz all skipped)" do
    assert_no_enqueued_jobs(only: [ ProcessEtJob, ProcessTrJob, ProcessCompDocsJob, ProcessKmzJob ]) do
      post conversations_path, params: {
        conversation: { client_name: "Cliente Sem Arquivos" }
      }
    end

    conversation = Conversation.order(:created_at).last
    assert_redirected_to conversation
    assert_equal "skipped", conversation.processing_step_status("et")
    assert_equal "skipped", conversation.processing_step_status("cal")
    assert_equal "skipped", conversation.processing_step_status("tr")
    assert_equal "skipped", conversation.processing_step_status("comp_docs")
    assert_equal "skipped", conversation.processing_step_status("kmz")
  end

  test "create re-renders the form with errors when client_name is missing" do
    assert_no_difference "Conversation.count" do
      post conversations_path, params: { conversation: { client_name: "" } }
    end

    assert_response :unprocessable_entity
  end

  test "create rejects an ET that isn't PDF or DOCX" do
    bad_et = fixture_file_upload("area_sample.kmz", "application/vnd.google-earth.kmz")

    assert_no_difference "Conversation.count" do
      post conversations_path, params: {
        conversation: { client_name: "Cliente Novo" }, et: bad_et
      }
    end

    assert_response :unprocessable_entity
  end

  test "create rejects a TR that isn't PDF or DOCX" do
    bad_tr = fixture_file_upload("area_sample.kmz", "application/vnd.google-earth.kmz")

    assert_no_difference "Conversation.count" do
      post conversations_path, params: {
        conversation: { client_name: "Cliente Novo" }, tr: bad_tr
      }
    end

    assert_response :unprocessable_entity
  end

  test "create accepts more than one ET file, attaching all of them with kind et" do
    ets = [ fixture_file_upload("tr_sample.pdf", "application/pdf"), fixture_file_upload("comp_sample.pdf", "application/pdf") ]

    post conversations_path, params: {
      conversation: { client_name: "Cliente ET Múltiplo" }, et: ets
    }

    conversation = Conversation.order(:created_at).last
    assert_redirected_to conversation
    assert_equal 2, conversation.attachments_of_kind("et").size
  end

  test "create accepts an optional TR alongside the ET, attaching it separately with kind tr" do
    et = fixture_file_upload("tr_sample.pdf", "application/pdf")
    tr = fixture_file_upload("comp_sample.pdf", "application/pdf")

    post conversations_path, params: {
      conversation: { client_name: "Cliente ET e TR" }, et: et, tr: tr
    }

    conversation = Conversation.order(:created_at).last
    assert_redirected_to conversation
    assert_equal 1, conversation.attachments_of_kind("et").size
    assert_equal 1, conversation.attachments_of_kind("tr").size
  end

  test "create rejects the whole batch when any of the multiple ET files isn't PDF or DOCX" do
    ets = [ fixture_file_upload("tr_sample.pdf", "application/pdf"), fixture_file_upload("area_sample.kmz", "application/vnd.google-earth.kmz") ]

    assert_no_difference "Conversation.count" do
      post conversations_path, params: {
        conversation: { client_name: "Cliente Novo" }, et: ets
      }
    end

    assert_response :unprocessable_entity
  end

  test "create rejects a KMZ with the wrong extension" do
    bad_kmz = fixture_file_upload("tr_sample.pdf", "application/pdf")

    assert_no_difference "Conversation.count" do
      post conversations_path, params: {
        conversation: { client_name: "Cliente Novo" }, kmz: bad_kmz
      }
    end

    assert_response :unprocessable_entity
  end

  test "show renders an existing conversation" do
    get conversation_path(conversations(:reviewing_conversation))
    assert_response :success
  end

  test "show renders a document attached to a message as a chip inside the bubble, not just in the sidebar" do
    conversation = conversations(:reviewing_conversation)
    message = conversation.messages.create!(role: "user", content: "essa é a versão final revisada", internal: false)
    message.attachments.attach(
      io: StringIO.new("conteúdo"), filename: "proposta_revisada.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      metadata: { kind: "complementary" }
    )

    get conversation_path(conversation)

    assert_response :success
    assert_match "essa é a versão final revisada", response.body
    assert_match "proposta_revisada.docx", response.body
  end

  test "show renders a message asking for a TR when the study type is not identified yet" do
    conversation = conversations(:reviewing_conversation)
    conversation.update_column(:study_type_id, nil)

    get conversation_path(conversation)

    assert_response :success
    assert_match "aguardando identificação", response.body
    assert_no_match "Avançar para Precificação\"", response.body # some, vira botão desabilitado
  end

  test "show renders a select to correct the study type once it's identified" do
    get conversation_path(conversations(:reviewing_conversation))

    assert_response :success
    assert_select "form[action=?]", conversation_path(conversations(:reviewing_conversation)) do
      assert_select "select[name=?]", "conversation[study_type_id]"
    end
  end

  test "update changes the study type" do
    conversation = conversations(:reviewing_conversation)

    patch conversation_path(conversation), params: { conversation: { study_type_id: study_types(:rap).id } }

    assert_redirected_to conversation
    assert_equal study_types(:rap), conversation.reload.study_type
  end

  test "show does not render the 'Gerados pela IA' divider when the proposal has no generated documents yet" do
    get conversation_path(conversations(:priced_conversation))

    assert_response :success
    assert_no_match "Gerados pela IA", response.body
  end

  test "show lists every generated document, all versions, newest first, under the 'Gerados pela IA' divider" do
    proposal = proposals(:priced_proposal)
    proposal.generated_documents.attach(
      io: StringIO.new("v1"), filename: "v1.docx", content_type: "application/octet-stream",
      metadata: { kind: "combined", version: 1, description: "Emissão Inicial" }
    )
    proposal.generated_documents.attach(
      io: StringIO.new("v2"), filename: "v2.docx", content_type: "application/octet-stream",
      metadata: { kind: "combined", version: 2, description: "Ajuste" }
    )

    get conversation_path(proposal.conversation)

    assert_response :success
    assert_match "Gerados pela IA", response.body
    assert_match "v2.docx", response.body
    assert_match "v1.docx", response.body
    assert_operator response.body.index("v2.docx"), :<, response.body.index("v1.docx")
  end
end
