# Extrai um Hash de uma resposta de texto da IA que devia ser JSON puro. Alguns providers
# (visto na prática com Gemini/Bedrock) embrulham a resposta em ```json ... ``` mesmo quando o
# prompt pede explicitamente "sem markdown" — sem tirar essa cerca antes, JSON.parse falha e
# qualquer código que dependa do resultado (ex.: identificar o tipo de estudo, montar o resumo
# estruturado) silenciosamente não encontra nada. Usado em todo lugar que lê de volta um JSON que
# a própria IA gerou — nunca confiar 100% no formato exato da resposta.
class AiJsonResponse
  def self.parse(text)
    return nil if text.blank?

    stripped = text.to_s.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "")
    JSON.parse(stripped)
  rescue JSON::ParserError, TypeError
    nil
  end
end
