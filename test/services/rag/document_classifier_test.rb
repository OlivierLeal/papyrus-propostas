require "test_helper"

class Rag::DocumentClassifierTest < ActiveSupport::TestCase
  setup do
    @job = build_job(
      "25001_Petrobras_Cetaceos/25001_Petrobras_Cetaceos_Rev00.docx",
      "25001_Petrobras_Cetaceos/Doc´s Cliente/Anexo 1 - Especificação Técnica.docx"
    )
  end

  test "usa o papel que a IA respondeu para cada caminho" do
    answer = {
      "25001_Petrobras_Cetaceos/25001_Petrobras_Cetaceos_Rev00.docx" => "proposta_papyrus",
      "25001_Petrobras_Cetaceos/Doc´s Cliente/Anexo 1 - Especificação Técnica.docx" => "tr_cliente"
    }

    result = classify_with_ai(answer)

    assert_equal "proposta_papyrus", result.values.first.role
    assert_equal "tr_cliente", result.values.second.role
    assert result.values.all? { |c| c.source == :ai }
  end

  test "descarta papel que não existe no menu e mantém a heurística" do
    answer = @job.items.to_h { |item| [ item.relative_path, "documento_secreto_inventado" ] }

    result = classify_with_ai(answer)

    assert result.values.all? { |c| c.source == :heuristic }, "papel fora do menu não pode entrar"
    assert result.values.all? { |c| Rag::DocumentClassifier::ROLES.key?(c.role) }
  end

  test "falha da IA não derruba a classificação do job" do
    stub_rag_chat_error do
      result = Rag::DocumentClassifier.new(@job).call

      assert_equal 2, result.size
      assert result.values.all? { |c| c.source == :heuristic }
    end
  end

  test "resposta da IA que não é JSON cai na heurística" do
    result = classify_with_ai_raw("desculpe, não consegui classificar")

    assert result.values.all? { |c| c.source == :heuristic }
  end

  test "sem IA, a heurística separa proposta da Papyrus de documento do cliente" do
    result = Rag::DocumentClassifier.new(@job, use_ai: false).call

    assert_equal "proposta_papyrus", result.values.first.role
    assert_equal "tr_cliente", result.values.second.role
  end

  test "só proposta e planilha da Papyrus contam como voz da Papyrus" do
    voice = Rag::DocumentClassifier::VOICE_OF_PAPYRUS

    assert_includes voice, "proposta_papyrus"
    assert_not_includes voice, "tr_cliente", "texto do cliente não pode ensinar a IA a escrever"
    assert_not_includes voice, "anexo_tecnico"
  end

  test "TR escrito pela Papyrus não conta como modelo de redação de proposta" do
    # Regressão: os "PR 25002 - Termo de Referência - Provedores..." eram classificados como
    # proposta_papyrus e entravam na voz da Papyrus. São TR de subcontratação — estrutura
    # diferente de proposta comercial, ensinariam a IA a escrever o documento errado.
    assert_includes Rag::DocumentClassifier::ROLES.keys, "tr_papyrus"
    assert_not_includes Rag::DocumentClassifier::VOICE_OF_PAPYRUS, "tr_papyrus"
  end

  test "heurística distingue TR da Papyrus de TR do cliente pelo caminho" do
    job = build_job(
      "25002_Renova/Doc´s Papyrus/PS/Termo/PR 25002 - Termo de Referência - Provedores.docx",
      "25002_Renova/Doc´s Clientes/Termo de Referência do cliente.docx"
    )

    roles = Rag::DocumentClassifier.new(job, use_ai: false).call.values.map(&:role)

    assert_equal %w[tr_papyrus tr_cliente], roles
  end

  private

  def build_job(*relative_paths)
    items = relative_paths.map do |relative_path|
      Rag::Inventory::Item.new(
        path: "/tmp/#{relative_path}", filename: File.basename(relative_path),
        relative_path: relative_path, sha256: "a" * 64, byte_size: 1, extension: "docx",
        numero_proposta: "25001", revision: 0, year: 2025, superseded: false, spreadsheet_path: nil
      )
    end

    Rag::Inventory::Job.new(path: "/tmp", name: "25001_Petrobras_Cetaceos", numero: "25001",
                            client_name: "Petrobras", subject: "Cetaceos", items: items)
  end

  def classify_with_ai(answer) = classify_with_ai_raw(answer.to_json)

  def classify_with_ai_raw(response)
    stub_rag_chat(response) { Rag::DocumentClassifier.new(@job).call }
  end
end
