# frozen_string_literal: true

# RubyLLM 1.16.0 normaliza inference profiles do Bedrock
# usando a região configurada:
#
#   global.anthropic.claude-sonnet-4-6
#              ↓
#   sa.anthropic.claude-sonnet-4-6
#
# Para inference profiles explícitos (global.*, us.*, eu.*, sa.*, etc.),
# devemos preservar o ID original.

module PapyrusRubyLLMBedrockPatch
  private

  def normalize_inference_profile_id(model_id, inference_types, _region)
    return model_id unless inference_types.include?("INFERENCE_PROFILE")
    return model_id if inference_types.include?("ON_DEMAND")

    model_id
  end
end

Rails.application.config.to_prepare do
  bedrock_models = RubyLLM::Providers::Bedrock::Models

  unless bedrock_models.ancestors.include?(PapyrusRubyLLMBedrockPatch)
    bedrock_models.singleton_class.prepend(
      Module.new do
        define_method(:normalize_inference_profile_id) do |model_id, inference_types, _region|
          return model_id unless inference_types.include?("INFERENCE_PROFILE")
          return model_id if inference_types.include?("ON_DEMAND")

          model_id
        end
      end
    )
  end
end