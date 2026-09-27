require "test_helper"

class SearchProjectPrecedentsToolTest < ActiveSupport::TestCase
  test "devolve a ficha estruturada com equipe, totais e referência" do
    precedent = JobPrecedent.new(
      job_number: "26098", client_name: "Newave", year: 2026, service: "Licenciamento de BESS",
      total_value: 185_000, duration: "24 meses",
      team: [ { "funcao" => "Meio Físico", "horas_homem" => 80, "diarias" => 5 }, { "funcao" => "Flora", "horas_homem" => 60 } ]
    )
    finder = FakeFinder.new([ Rag::PrecedentFinder::Match.new(precedent: precedent, similarity: 0.82) ])

    result = JSON.parse(SearchProjectPrecedentsTool.new(finder: finder).execute(busca: "BESS na Bahia"))

    item = result["resultados"].first
    assert_equal "acervo Papyrus: projeto 26098 — Newave — 2026", item["referencia"]
    assert_equal 185_000.0, item["valor_total"]
    assert_equal 140.0, item["total_horas_homem"]
    assert_equal 2, item["equipe"].size
    assert_match "nunca preço", result["instrucao"]
    assert_equal "BESS na Bahia", finder.descriptor
  end

  test "sem busca, usa o escopo da própria proposta" do
    conversation = conversations(:reviewing_conversation)
    finder = FakeFinder.new([])

    SearchProjectPrecedentsTool.new(conversation: conversation, finder: finder).execute

    assert_equal conversation.service_descriptor, finder.descriptor
  end

  FakeFinder = Struct.new(:matches, :descriptor) do
    def call(descriptor, **)
      self.descriptor = descriptor
      matches
    end
  end
end
