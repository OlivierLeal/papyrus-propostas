RubyLLM.configure do |config|
  # TEMPORÁRIO: usando Gemini enquanto não temos a chave da Anthropic. Produção usa Claude API (ver CLAUDE.md).
  # Pra voltar pro Claude: comente as duas linhas do Gemini abaixo e descomente as duas do Anthropic.
  config.bedrock_api_key = ENV["AWS_ACCESS_KEY_ID"]
  config.bedrock_secret_key = ENV["AWS_SECRET_ACCESS_KEY"]
  config.bedrock_region = ENV["AWS_REGION"]
  config.default_model = "global.anthropic.claude-haiku-4-5-20251001-v1:0"

  # config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY", Rails.application.credentials.dig(:anthropic_api_key))
  # config.default_model = "claude-sonnet-4-5"

  # Use the association-based acts_as API (recommended)
  config.use_new_acts_as = true
end
