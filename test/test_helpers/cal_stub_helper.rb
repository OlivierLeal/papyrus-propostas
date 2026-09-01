# CAL_EMAIL/CAL_PASSWORD vêm do .env real do ambiente de quem roda os testes (dotenv-rails carrega
# em todo RAILS_ENV, inclusive test) — qualquer teste que dependa de Cal::Client.configured? ser
# true ou false não pode depender do que estiver no .env de quem roda, senão passa numa máquina e
# quebra em outra. Controla o estado explicitamente.
module CalStubHelper
  def with_cal_configured
    with_env("CAL_EMAIL" => "consultor@papyrus.com", "CAL_PASSWORD" => "segredo") { yield }
  end

  def without_cal_configured
    with_env("CAL_EMAIL" => nil, "CAL_PASSWORD" => nil) { yield }
  end

  private

  def with_env(values)
    originals = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| ENV[key] = value }
  end
end
