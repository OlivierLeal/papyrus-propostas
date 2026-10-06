require "test_helper"

class TermOfReferenceCandidatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one) # não é o dono da conversa: qualquer consultor decide
    @conversation = conversations(:priced_conversation)
    @candidate = @conversation.term_of_reference_candidates.create!(source: "cal", norm_code: "NL555", title: "Portaria TR")
  end

  test "aceitar enfileira a busca do arquivo e redesenha o card" do
    assert_enqueued_with(job: AcceptTermOfReferenceJob, args: [ @candidate.id ]) do
      post accept_conversation_term_of_reference_candidate_path(@conversation, @candidate), as: :turbo_stream
    end
    assert @candidate.reload.accepting?
    assert_equal users(:one), @candidate.decided_by
    assert_match "Buscando o arquivo", response.body
  end

  test "descartar" do
    post reject_conversation_term_of_reference_candidate_path(@conversation, @candidate)
    assert @candidate.reload.rejected?
    assert_redirected_to @conversation
  end
end
