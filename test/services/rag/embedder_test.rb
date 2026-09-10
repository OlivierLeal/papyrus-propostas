require "test_helper"

module Rag
  # O Embedder assina e faz a chamada HTTP ao Bedrock na mão (o ruby_llm não tem provider de
  # embedding pra Bedrock). Nenhum teste pode bater na rede: `Net::HTTP.start` é stubado e a
  # resposta do Cohere é montada à mão, exercitando batching, extração de vetor (v3 x v4),
  # contagem e assinatura SigV4.
  class EmbedderTest < ActiveSupport::TestCase
    CREDS = { "AWS_ACCESS_KEY_ID" => "AKIATESTFAKE", "AWS_SECRET_ACCESS_KEY" => "segredo-fake", "AWS_REGION" => "sa-east-1" }.freeze

    test "lista vazia não gera chamada nenhuma" do
      with_env(CREDS) do
        stub_bedrock([]) do |captured|
          assert_empty Embedder.new.embed_documents([])
          assert_empty captured
        end
      end
    end

    test "devolve um vetor por texto, na mesma ordem" do
      with_env(CREDS) do
        stub_bedrock([ vectors_response([ [ 1.0 ], [ 2.0 ], [ 3.0 ] ]) ]) do |captured|
          result = Embedder.new.embed_documents(%w[a b c])

          assert_equal [ [ 1.0 ], [ 2.0 ], [ 3.0 ] ], result
          assert_equal 1, captured.size
          assert_equal "search_document", JSON.parse(captured.first.body)["input_type"]
        end
      end
    end

    test "quebra em lotes de no máximo MAX_TEXTS_PER_CALL e concatena na ordem" do
      texts = Array.new(Embedder::MAX_TEXTS_PER_CALL + 4) { |i| "t#{i}" }
      batch_one = vectors_response(Array.new(Embedder::MAX_TEXTS_PER_CALL) { [ 0.1 ] })
      batch_two = vectors_response(Array.new(4) { [ 0.2 ] })

      with_env(CREDS) do
        stub_bedrock([ batch_one, batch_two ]) do |captured|
          result = Embedder.new.embed_documents(texts)

          assert_equal texts.size, result.size
          assert_equal 2, captured.size
          assert_equal Embedder::MAX_TEXTS_PER_CALL, JSON.parse(captured.first.body)["texts"].size
          assert_equal 4, JSON.parse(captured.second.body)["texts"].size
        end
      end
    end

    test "embed_query usa search_query e devolve um vetor só" do
      with_env(CREDS) do
        stub_bedrock([ vectors_response([ [ 9.0, 9.0 ] ]) ]) do |captured|
          assert_equal [ 9.0, 9.0 ], Embedder.new.embed_query("consulta")
          assert_equal "search_query", JSON.parse(captured.first.body)["input_type"]
        end
      end
    end

    test "entende a resposta do Cohere v4, com os vetores aninhados em float" do
      with_env(CREDS) do
        stub_bedrock([ json_response(200, "embeddings" => { "float" => [ [ 4.0 ], [ 5.0 ] ] }) ]) do
          assert_equal [ [ 4.0 ], [ 5.0 ] ], Embedder.new.embed_documents(%w[a b])
        end
      end
    end

    test "número de vetores diferente do número de textos é erro" do
      with_env(CREDS) do
        stub_bedrock([ vectors_response([ [ 1.0 ] ]) ]) do
          assert_raises(Embedder::Error) { Embedder.new.embed_documents(%w[a b]) }
        end
      end
    end

    test "resposta não-200 vira Embedder::Error com o corpo truncado" do
      with_env(CREDS) do
        stub_bedrock([ json_response(500, "ThrottlingException") ]) do
          error = assert_raises(Embedder::Error) { Embedder.new.embed_documents(%w[a]) }
          assert_match(/500/, error.message)
        end
      end
    end

    test "sem credencial AWS, falha antes de qualquer chamada HTTP" do
      with_env("AWS_ACCESS_KEY_ID" => nil, "AWS_SECRET_ACCESS_KEY" => nil) do
        stub_bedrock([]) do |captured|
          assert_raises(Embedder::Error) { Embedder.new.embed_documents(%w[a]) }
          assert_empty captured
        end
      end
    end

    test "a requisição vai assinada em SigV4 e com o content-type certo" do
      with_env(CREDS) do
        stub_bedrock([ vectors_response([ [ 1.0 ] ]) ]) do |captured|
          Embedder.new.embed_documents(%w[a])
          request = captured.first

          assert_equal "application/json", request["content-type"]
          assert_match(/\AAWS4-HMAC-SHA256 Credential=AKIATESTFAKE\//, request["authorization"])
          assert_match(/SignedHeaders=.*host.*x-amz-date/, request["authorization"])
          assert request["x-amz-date"].present?
          assert_equal Digest::SHA256.hexdigest(request.body), request["x-amz-content-sha256"]
          assert_equal "END", JSON.parse(request.body)["truncate"]
        end
      end
    end

    private

    def vectors_response(list) = json_response(200, "embeddings" => list)

    def json_response(code, body_hash)
      klass = Net::HTTPResponse::CODE_TO_OBJ[code.to_s] || Net::HTTPOK
      response = klass.new("1.1", code.to_s, "")
      json = JSON.generate(body_hash)
      response.define_singleton_method(:body) { json }
      response
    end

    # Substitui Net::HTTP.start por um fake que captura cada request e devolve as respostas na
    # ordem. Passa o array de requests capturados pro bloco.
    def stub_bedrock(responses)
      queue = responses.dup
      captured = []
      fake_http = Object.new
      fake_http.define_singleton_method(:request) do |request|
        captured << request
        queue.shift || raise("stub sem resposta suficiente")
      end

      original = Net::HTTP.method(:start)
      Net::HTTP.define_singleton_method(:start) { |*_args, **_kwargs, &block| block.call(fake_http) }

      yield captured
    ensure
      Net::HTTP.define_singleton_method(:start, original)
    end
  end
end
