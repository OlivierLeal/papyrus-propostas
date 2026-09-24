# TAVILY_API_KEY vem do .env real do ambiente de quem roda os testes (dotenv-rails carrega em
# todo RAILS_ENV, inclusive test) — mesmo motivo de CalStubHelper: qualquer teste que dependa de
# WebSearch::Client.configured? não pode depender do que estiver no .env de quem roda.
module WebSearchStubHelper
  def with_web_search_configured
    with_env("TAVILY_API_KEY" => "chave-de-teste") { yield }
  end

  def without_web_search_configured
    with_env("TAVILY_API_KEY" => nil) { yield }
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
