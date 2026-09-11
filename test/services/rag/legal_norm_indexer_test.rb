require "test_helper"

module Rag
  class LegalNormIndexerTest < ActiveSupport::TestCase
    test "salva o registro, chunka o texto e embeda os chunks" do
      record = LegalNorm.new(codigo: "NL9924", tipo_e_numero: "Resolução CONAMA 1/86", referencia: "NL9924 — Resolução CONAMA 1/86 (CAL/Ius Natura)")
      text = "Dispõe sobre o Estudo e o Relatório de Impacto Ambiental. #{'Artigo de teste. ' * 20}"

      stub_embedder { Rag::LegalNormIndexer.new(record, text).call! }

      assert record.persisted?
      assert record.chunks.any?
      assert record.chunks.all? { |chunk| chunk.embedding.present? }
    end

    test "rodar de novo sobre o mesmo registro substitui os chunks em vez de duplicar" do
      record = LegalNorm.create!(codigo: "NL9924", referencia: "NL9924 — Resolução CONAMA 1/86 (CAL/Ius Natura)")
      text = "Texto original da norma. #{'Artigo de teste. ' * 20}"

      stub_embedder do
        Rag::LegalNormIndexer.new(record, text).call!
        first_count = record.chunks.count

        Rag::LegalNormIndexer.new(record, text).call!
        assert_equal first_count, record.chunks.count
      end
    end
  end
end
