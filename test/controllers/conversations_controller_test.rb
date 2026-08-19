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

  test "create persists the conversation, applies system instructions and enqueues all processing jobs" do
    tr = fixture_file_upload("tr_sample.pdf", "application/pdf")
    kmz = fixture_file_upload("area_sample.kmz", "application/vnd.google-earth.kmz")

    assert_enqueued_with(job: ProcessTrJob) do
      assert_enqueued_with(job: ProcessCompDocsJob) do
        assert_enqueued_with(job: ProcessKmzJob) do
          assert_difference "Conversation.count", 1 do
            post conversations_path, params: {
              conversation: { client_name: "Cliente Novo", study_type_id: study_types(:eia_rima).id },
              tr: tr, kmz: kmz, complementary_documents: [ fixture_file_upload("comp_sample.pdf", "application/pdf") ]
            }
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

  test "create works with no attachments at all (tr, comp_docs and kmz all skipped)" do
    assert_no_enqueued_jobs(only: [ ProcessTrJob, ProcessCompDocsJob, ProcessKmzJob ]) do
      post conversations_path, params: {
        conversation: { client_name: "Cliente Sem Arquivos", study_type_id: study_types(:eia_rima).id }
      }
    end

    conversation = Conversation.order(:created_at).last
    assert_redirected_to conversation
    assert_equal "skipped", conversation.processing_step_status("tr")
    assert_equal "skipped", conversation.processing_step_status("comp_docs")
    assert_equal "skipped", conversation.processing_step_status("kmz")
  end

  test "create re-renders the form with errors when client_name is missing" do
    assert_no_difference "Conversation.count" do
      post conversations_path, params: { conversation: { client_name: "", study_type_id: study_types(:eia_rima).id } }
    end

    assert_response :unprocessable_entity
  end

  test "create rejects a TR that isn't PDF or DOCX" do
    bad_tr = fixture_file_upload("area_sample.kmz", "application/vnd.google-earth.kmz")

    assert_no_difference "Conversation.count" do
      post conversations_path, params: {
        conversation: { client_name: "Cliente Novo", study_type_id: study_types(:eia_rima).id }, tr: bad_tr
      }
    end

    assert_response :unprocessable_entity
  end

  test "create rejects a KMZ with the wrong extension" do
    bad_kmz = fixture_file_upload("tr_sample.pdf", "application/pdf")

    assert_no_difference "Conversation.count" do
      post conversations_path, params: {
        conversation: { client_name: "Cliente Novo", study_type_id: study_types(:eia_rima).id }, kmz: bad_kmz
      }
    end

    assert_response :unprocessable_entity
  end

  test "show renders an existing conversation" do
    get conversation_path(conversations(:reviewing_conversation))
    assert_response :success
  end
end
