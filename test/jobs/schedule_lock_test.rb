require "test_helper"

# Precisa de conexões de banco DE VERDADE por thread (não a conexão compartilhada dos testes
# transacionais) pra reproduzir a corrida de verdade entre dois jobs concorrentes pra MESMA
# proposta — exatamente o que Proposal#with_schedule_lock precisa provar que evita. Achado ao
# vivo no chat 32 (CLAUDE.md seção 8, "saiu muita coisa repetida no cronograma"): duas chamadas
# de "gerar cronograma" a ~40s de distância passaram as duas pela checagem "já existe item?"
# antes de qualquer uma ter terminado de chamar a IA, e as duas construíram o cronograma inteiro
# em paralelo.
class ScheduleLockTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @proposal = proposals(:priced_proposal)
  end

  teardown do
    @proposal.project_pricing.schedule_items.destroy_all
    @proposal.project_pricing.update!(schedule_key_points: [])
  end

  test "SuggestScheduleJob serializes concurrent runs instead of building the schedule twice" do
    original_method = Conversation.instance_method(:complete)
    # Sono proposital: sem a trava, dá tempo da outra thread passar pela checagem "já existe
    # item?" enquanto nenhuma das duas terminou de inserir nada ainda — a corrida vista no chat 32.
    Conversation.define_method(:complete) do
      sleep 0.05
      messages.create!(role: "assistant", content: <<~JSON)
        {"cronograma_servico": [{"fase": "Mobilização", "atividade": "Contrato", "periodo_inicio": 1, "duracao": 1, "marco": false}], "cronograma_implantacao": []}
      JSON
    end

    threads = [
      Thread.new { SuggestScheduleJob.new.perform(@proposal.id) },
      Thread.new { SuggestScheduleJob.new.perform(@proposal.id) }
    ]
    threads.each(&:join)

    assert_equal 1, @proposal.project_pricing.schedule_items.count,
      "as duas chamadas concorrentes deveriam produzir UM cronograma só, não um duplicado"
  ensure
    Conversation.define_method(:complete, original_method)
  end

  test "ElectScheduleKeyPointsJob serializes concurrent runs instead of calling the AI twice" do
    @proposal.project_pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização",
      activity_name: "Contrato", start_period: 1, duration_periods: 1, position: 0)

    calls = 0
    mutex = Mutex.new
    original_method = Conversation.instance_method(:complete)
    Conversation.define_method(:complete) do
      mutex.synchronize { calls += 1 }
      sleep 0.05
      messages.create!(role: "assistant", content: '{"marcos_infografico": [{"nome": "Contrato", "periodo": 1}]}')
    end

    threads = [
      Thread.new { ElectScheduleKeyPointsJob.new.perform(@proposal.id) },
      Thread.new { ElectScheduleKeyPointsJob.new.perform(@proposal.id) }
    ]
    threads.each(&:join)

    assert_equal 1, calls, "a segunda chamada deveria ver schedule_key_points já preenchido e desistir, sem chamar a IA de novo"
  ensure
    Conversation.define_method(:complete, original_method)
  end
end
