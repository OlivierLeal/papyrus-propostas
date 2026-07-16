RubyLLM.configure do |config|
  # TEMPORÁRIO: usando Gemini enquanto não temos a chave da Anthropic. Produção usa Claude API (ver CLAUDE.md).
  # Pra voltar pro Claude: comente as duas linhas do Gemini abaixo e descomente as duas do Anthropic.
  config.gemini_api_key = ENV.fetch("GEMINI_API_KEY", Rails.application.credentials.dig(:gemini_api_key))
  config.default_model = "gemini-2.5-flash"

  # config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY", Rails.application.credentials.dig(:anthropic_api_key))
  # config.default_model = "claude-sonnet-4-5"

  # Use the association-based acts_as API (recommended)
  config.use_new_acts_as = true
end
