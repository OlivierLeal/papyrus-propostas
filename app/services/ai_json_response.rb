# Extrai um Hash de uma resposta de texto da IA que devia ser JSON puro. Alguns providers
# (visto na prática com Gemini/Bedrock) embrulham a resposta em ```json ... ``` mesmo quando o
# prompt pede explicitamente "sem markdown" — sem tirar essa cerca antes, JSON.parse falha e
# qualquer código que dependa do resultado (ex.: identificar o tipo de estudo, montar o resumo
# estruturado) silenciosamente não encontra nada. Usado em todo lugar que lê de volta um JSON que
# a própria IA gerou — nunca confiar 100% no formato exato da resposta.
class AiJsonResponse
  # A cerca (e o texto antes dela) não precisa estar na âncora do início da string — achado numa
  # pesquisa real: depois de usar uma ferramenta algumas vezes (ver ProcessLegalNormsJob), a IA
  # tende a narrar um resumo do que fez ("Com base na pesquisa, identifiquei...") antes do bloco
  # ```json, mesmo o prompt pedindo pra não fazer isso — e um achado real inteiro (7 itens, texto
  # de norma incluído) se perdeu em silêncio por causa disso. Busca a cerca EM QUALQUER POSIÇÃO da
  # string; sem cerca nenhuma, cai para o primeiro "{" até o último "}" (json solto no meio de
  # texto) antes de desistir.
  FENCED = /```(?:json)?\s*(\{.*\})\s*```/mi
  BRACES = /\{.*\}/m

  def self.parse(text)
    return nil if text.blank?

    JSON.parse(extract(text.to_s))
  rescue JSON::ParserError, TypeError
    nil
  end

  def self.extract(text)
    fenced = text.match(FENCED)
    return fenced[1] if fenced

    braces = text.match(BRACES)
    braces ? braces[0] : text
  end
  private_class_method :extract
end
