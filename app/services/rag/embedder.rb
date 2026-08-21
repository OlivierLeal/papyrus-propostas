module Rag
  # Gera embeddings no Bedrock para a busca por similaridade do acervo (CLAUDE.md seção 11.1).
  #
  # Por que HTTP na mão em vez da gem: o ruby_llm não tem provider de embedding para Bedrock
  # (só chat) — o provider da Anthropic levanta erro explícito e não existe bedrock/embeddings.
  # Como só falta a assinatura SigV4, ela é feita aqui, sem arrastar o aws-sdk inteiro para o
  # projeto por causa de uma chamada.
  #
  # Modelo: cohere.embed-multilingual-v3, on-demand em sa-east-1. O embed-v4 é mais novo e
  # melhor, mas nesta região só roda pelo perfil "global.cohere.embed-v4:0", que faz
  # roteamento cross-region — e o acervo tem nome de cliente, CNPJ e preço, então o dado fica
  # no Brasil. Custo não é critério aqui: o acervo inteiro embeda por cerca de US$ 1.
  class Embedder
    MODEL_ID = "cohere.embed-multilingual-v3"
    DIMENSIONS = 1024
    SERVICE = "bedrock"

    # O Cohere v3 trunca a 512 tokens por texto e aceita no máximo 96 textos por chamada.
    MAX_TEXTS_PER_CALL = 96

    # search_document é o modo para o que vai PARA o índice; a consulta usa search_query.
    # Usar o mesmo tipo nos dois lados piora a recuperação — o modelo é treinado assimétrico.
    INPUT_DOCUMENT = "search_document"
    INPUT_QUERY = "search_query"

    class Error < StandardError; end

    def initialize(region: nil, model_id: MODEL_ID)
      @region = region || ENV.fetch("AWS_REGION", "sa-east-1")
      @model_id = model_id
    end

    # Recebe textos, devolve um vetor por texto, na mesma ordem.
    def embed_documents(texts) = embed(texts, INPUT_DOCUMENT)

    def embed_query(text) = embed([ text ], INPUT_QUERY).first

    private

    def embed(texts, input_type)
      texts = Array(texts)
      return [] if texts.empty?

      texts.each_slice(MAX_TEXTS_PER_CALL).flat_map do |batch|
        invoke(batch, input_type)
      end
    end

    def invoke(texts, input_type)
      body = JSON.generate(
        texts: texts,
        input_type: input_type,
        # Sem isso, um texto acima do limite do modelo faz a chamada inteira falhar em vez de
        # só perder a cauda — o chunker já corta abaixo de 512 tokens, isto é rede de segurança.
        truncate: "END"
      )

      response = post(body)
      vectors = extract_vectors(response)
      raise Error, "esperava #{texts.size} vetores, vieram #{vectors.size}" unless vectors.size == texts.size

      vectors
    end

    # A resposta do Cohere v3 traz "embeddings" como lista; a v4 aninha em {"float" => [...]}.
    def extract_vectors(payload)
      embeddings = payload["embeddings"]
      return embeddings["float"] if embeddings.is_a?(Hash)

      embeddings.to_a
    end

    def post(body)
      uri = URI("https://bedrock-runtime.#{@region}.amazonaws.com/model/#{CGI.escape(@model_id)}/invoke")

      request = Net::HTTP::Post.new(uri)
      request["content-type"] = "application/json"
      request.body = body
      sign!(request, uri, body)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) do |http|
        http.request(request)
      end
      raise Error, "Bedrock #{response.code}: #{response.body.to_s.truncate(300)}" unless response.code == "200"

      JSON.parse(response.body)
    end

    # ---- SigV4 -----------------------------------------------------------------
    # Assinatura AWS versão 4, escopo bedrock. Mesma mecânica de
    # ruby_llm/providers/bedrock/auth.rb, reduzida ao caso de um POST único.

    def sign!(request, uri, body)
      now = Time.now.utc
      amz_date = now.strftime("%Y%m%dT%H%M%SZ")
      date_stamp = now.strftime("%Y%m%d")
      payload_hash = Digest::SHA256.hexdigest(body)

      headers = {
        "host" => uri.host,
        "x-amz-content-sha256" => payload_hash,
        "x-amz-date" => amz_date
      }
      headers["x-amz-security-token"] = session_token if session_token.present?

      signed_headers = headers.keys.sort.join(";")
      canonical = [
        "POST", uri.path, "",
        headers.sort.map { |key, value| "#{key}:#{value}\n" }.join,
        signed_headers, payload_hash
      ].join("\n")

      scope = "#{date_stamp}/#{@region}/#{SERVICE}/aws4_request"
      to_sign = [ "AWS4-HMAC-SHA256", amz_date, scope, Digest::SHA256.hexdigest(canonical) ].join("\n")
      signature = OpenSSL::HMAC.hexdigest("sha256", signing_key(date_stamp), to_sign)

      headers.each { |key, value| request[key] = value }
      request["authorization"] = "AWS4-HMAC-SHA256 Credential=#{access_key_id}/#{scope}, " \
                                 "SignedHeaders=#{signed_headers}, Signature=#{signature}"
    end

    def signing_key(date_stamp)
      key = OpenSSL::HMAC.digest("sha256", "AWS4#{secret_access_key}", date_stamp)
      key = OpenSSL::HMAC.digest("sha256", key, @region)
      key = OpenSSL::HMAC.digest("sha256", key, SERVICE)
      OpenSSL::HMAC.digest("sha256", key, "aws4_request")
    end

    def access_key_id
      ENV["AWS_ACCESS_KEY_ID"].presence || raise(Error, "AWS_ACCESS_KEY_ID não configurada")
    end

    def secret_access_key
      ENV["AWS_SECRET_ACCESS_KEY"].presence || raise(Error, "AWS_SECRET_ACCESS_KEY não configurada")
    end

    def session_token = ENV["AWS_SESSION_TOKEN"]
  end
end
