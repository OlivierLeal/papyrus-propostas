require "test_helper"

module Rag
  class ProposalIndexerTest < ActiveSupport::TestCase
    test "salva o registro, chunka o texto e embeda os chunks" do
      record = HistoricalProposal.new(
        source_sha256: SecureRandom.hex(32), origin: "revisao_manual", job_name: "PTC26099",
        job_number: "PTC26099", client_name: "Cliente Teste", source_path: "active_storage:x",
        relative_path: "proposta.docx", filename: "proposta.docx", chunker_version: "1",
        role: "proposta_papyrus", role_source: "consultor", status: "ok"
      )
      text = "1. OBJETIVO DOS SERVIÇOS\n\n#{'Elaboração de estudo ambiental para licenciamento. ' * 10}"

      stub_embedder { Rag::ProposalIndexer.new(record, text).call! }

      assert record.persisted?
      assert record.chunks.any?
      assert record.chunks.all? { |chunk| chunk.embedding.present? }
    end

    test "rodar de novo sobre o mesmo registro substitui os chunks em vez de duplicar" do
      record = HistoricalProposal.create!(
        source_sha256: SecureRandom.hex(32), origin: "revisao_manual", job_name: "PTC26099",
        job_number: "PTC26099", client_name: "Cliente Teste", source_path: "active_storage:x",
        relative_path: "proposta.docx", filename: "proposta.docx", chunker_version: "1",
        role: "proposta_papyrus", role_source: "consultor", status: "ok"
      )
      text = "1. OBJETIVO DOS SERVIÇOS\n\n#{'Texto original. ' * 10}"

      stub_embedder do
        Rag::ProposalIndexer.new(record, text).call!
        first_count = record.chunks.count

        Rag::ProposalIndexer.new(record, text).call!
        assert_equal first_count, record.chunks.count
      end
    end
  end
end
