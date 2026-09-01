require "test_helper"

module Cal
  class ClientTest < ActiveSupport::TestCase
    LOGIN_HTML = <<~HTML.freeze
      <html><body><form action="/Account/Login" method="post">
        <input name="__RequestVerificationToken" type="hidden" value="token-abc" />
      </form></body></html>
    HTML

    DASHBOARD_HTML = "<html><head><title>Dashboard | CAL®</title></head><body></body></html>".freeze

    setup do
      # cache_store de teste é :null_store (nunca guarda nada) — troca por um MemoryStore de
      # verdade só nestes testes, porque reuso de sessão cacheada é justamente o que testamos.
      @original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      @client = Cal::Client.new(email: "consultor@papyrus.com", password: "segredo")
    end

    teardown do
      Rails.cache = @original_cache
    end

    test "requires email and password" do
      assert_raises(Cal::Client::AuthenticationError) { Cal::Client.new(email: nil, password: "x") }
      assert_raises(Cal::Client::AuthenticationError) { Cal::Client.new(email: "x@x.com", password: "") }
    end

    test "configured? reflects whether CAL_EMAIL/CAL_PASSWORD are set" do
      original_email, original_password = ENV["CAL_EMAIL"], ENV["CAL_PASSWORD"]
      ENV["CAL_EMAIL"] = "x@x.com"
      ENV["CAL_PASSWORD"] = "y"
      assert Cal::Client.configured?

      ENV["CAL_PASSWORD"] = nil
      assert_not Cal::Client.configured?
    ensure
      ENV["CAL_EMAIL"] = original_email
      ENV["CAL_PASSWORD"] = original_password
    end

    test "get performs the login flow once and reuses the cached session on the next call" do
      responses = [
        html_response(200, LOGIN_HTML, set_cookie: "ASP.NET_SessionId=s1"),                 # GET /Account/Login (login!)
        redirect_response("/Home/Index", set_cookie: ".AspNet.ApplicationCookie=auth1"),     # POST /Account/Login
        html_response(200, DASHBOARD_HTML),                                                  # GET /Home/Index (segue o redirect)
        html_response(200, "<html>conteúdo autenticado</html>")                              # GET real que o chamador pediu
      ]

      stub_requests(responses) do
        response = @client.get("/NormaLegalBdCliente")
        assert_equal "conteúdo autenticado", strip_tags(response.body)
      end

      assert Rails.cache.read(Cal::Client::SESSION_CACHE_KEY).present?

      stub_requests([ html_response(200, "<html>segunda chamada</html>") ]) do
        response = @client.get("/NormaLegalBdCliente")
        assert_equal "segunda chamada", strip_tags(response.body)
      end
    end

    test "raises AuthenticationError when the CSRF token is missing from the login page" do
      stub_requests([ html_response(200, "<html>sem token nenhum</html>") ]) do
        assert_raises(Cal::Client::AuthenticationError) { @client.get("/qualquer") }
      end
    end

    test "raises AuthenticationError when the post-login page isn't the Dashboard" do
      responses = [
        html_response(200, LOGIN_HTML),
        redirect_response("/Home/Index"),
        html_response(200, "<html><title>Não Autorizado</title></html>")
      ]

      stub_requests(responses) do
        assert_raises(Cal::Client::AuthenticationError) { @client.get("/qualquer") }
      end
    end

    test "relogs automatically when a request comes back redirected to the login page (expired session)" do
      Rails.cache.write(Cal::Client::SESSION_CACHE_KEY, { "ASP.NET_SessionId" => "stale" })

      responses = [
        redirect_response("/Account/Login"),               # a chamada autenticada volta pro login = expirou
        html_response(200, LOGIN_HTML),                     # login! de novo
        redirect_response("/Home/Index"),
        html_response(200, DASHBOARD_HTML),
        html_response(200, "<html>agora sim</html>")        # reexecuta o get original
      ]

      stub_requests(responses) do
        response = @client.get("/NormaLegalBdCliente")
        assert_equal "agora sim", strip_tags(response.body)
      end
    end

    test "post_form sends the params and the extra headers" do
      captured = []
      responses = [
        html_response(200, LOGIN_HTML), redirect_response("/Home/Index"), html_response(200, DASHBOARD_HTML),
        html_response(200, "{}")
      ]
      on_request = ->(req) { captured << req if req.is_a?(Net::HTTP::Post) && req.path == "/NormaLegalBdCliente/Search" }

      stub_requests(responses, on_request: on_request) do
        @client.post_form("/NormaLegalBdCliente/Search", { "PalavraChave" => "fauna" }, extra_headers: { "TabId" => "ad02" })
      end

      assert_equal 1, captured.size
      assert_equal "ad02", captured.first["TabId"]
      assert_includes captured.first.body, "PalavraChave=fauna"
    end

    test "download follows the signed CDN redirect without sending CAL cookies to it" do
      responses = [
        html_response(200, LOGIN_HTML), redirect_response("/Home/Index"), html_response(200, DASHBOARD_HTML),
        redirect_response("https://files.sistemacal.com.br/files/abc.pdf?Signature=xyz")
      ]

      file_request = nil
      bytes = content_type = nil

      stub_requests(responses) do
        stub_get_response(body: "%PDF-1.4 conteúdo do pdf", content_type: "application/pdf", capture: ->(uri) { file_request = uri }) do
          bytes, content_type = @client.download("/UploadArquivo/ObterPdfPorNome?nome=abc")
        end
      end

      assert_equal "https://files.sistemacal.com.br/files/abc.pdf?Signature=xyz", file_request.to_s
      assert_equal "application/pdf", content_type
      assert_includes bytes, "conteúdo do pdf"
    end

    test "download returns nil when the CAL doesn't redirect to a file" do
      responses = [
        html_response(200, LOGIN_HTML), redirect_response("/Home/Index"), html_response(200, DASHBOARD_HTML),
        html_response(200, "<html>não é redirect nenhum</html>")
      ]

      stub_requests(responses) do
        assert_nil @client.download("/UploadArquivo/ObterPdfPorNome?nome=abc")
      end
    end

    private
      def html_response(code, body, set_cookie: nil)
        res = Net::HTTPOK.new("1.1", code.to_s, "")
        res.instance_variable_set(:@read, true)
        res.instance_variable_set(:@body, body)
        res["Set-Cookie"] = set_cookie if set_cookie
        res
      end

      def redirect_response(location, set_cookie: nil)
        res = Net::HTTPFound.new("1.1", "302", "Found")
        res.instance_variable_set(:@read, true)
        res.instance_variable_set(:@body, "")
        res["location"] = location
        res["Set-Cookie"] = set_cookie if set_cookie
        res
      end

      # Substitui Net::HTTP#request por uma fila de respostas pré-fabricadas, na ordem em que o
      # client faz as chamadas — não faz nenhuma requisição de rede de verdade. RESTAURA o método
      # original no fim (nunca remove_method): Net::HTTP é uma classe global compartilhada pela
      # suíte inteira, e removê-lo de vez derrubaria qualquer outro teste (rodando depois deste,
      # na mesma suíte) que precise do #request real — já visto quebrar MapboxStaticMapTest.
      def stub_requests(responses, on_request: nil)
        queue = responses.dup
        original = Net::HTTP.instance_method(:request)

        Net::HTTP.define_method(:request) do |*args|
          on_request&.call(*args)
          queue.shift or raise("fila de respostas do teste esgotada")
        end

        yield
      ensure
        Net::HTTP.define_method(:request, original)
      end

      # Mesma ideia de stub_requests, mas pro método de CLASSE Net::HTTP.get_response (usado só
      # em Cal::Client#download, pra baixar o arquivo da URL assinada do CDN — sem sessão, sem
      # cookies, por isso não passa pelo #request de instância acima).
      def stub_get_response(body:, content_type:, capture: nil)
        original = Net::HTTP.method(:get_response)

        Net::HTTP.define_singleton_method(:get_response) do |uri|
          capture&.call(uri)
          res = Net::HTTPOK.new("1.1", "200", "OK")
          res.instance_variable_set(:@read, true)
          res.instance_variable_set(:@body, body)
          res["content-type"] = content_type
          res
        end

        yield
      ensure
        Net::HTTP.define_singleton_method(:get_response, original)
      end

      def strip_tags(html)
        Nokogiri::HTML(html).at_css("body").text.strip
      end
  end
end
