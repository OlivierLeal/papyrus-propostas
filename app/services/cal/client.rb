require "net/http"

module Cal
  # Cliente HTTP autenticado pro sistema CAL da Ius Natura (sistemacal.com.br) — base de normas
  # legais que a Papyrus assina, usada aqui só como referência pra fundamentar a proposta (nunca
  # decide escopo/preço sozinha). Reproduz apenas as requisições que o próprio consultor faria
  # navegando no CAL, com a conta autorizada da Papyrus — sem contornar CAPTCHA, MFA ou qualquer
  # controle de acesso, e sem acessar dados de outra conta.
  #
  # O CAL é uma aplicação ASP.NET MVC clássica: login por formulário com token
  # __RequestVerificationToken, sessão mantida por cookie (.AspNet.ApplicationCookie entre
  # outros), sem API REST própria — então esta classe reproduz o fluxo de navegador (cookie jar
  # manual + redirects seguidos à mão, porque Net::HTTP não segue redirect sozinho) em vez de
  # chamar um endpoint documentado. Descoberto navegando o CAL de verdade com DevTools aberto;
  # qualquer endpoint novo precisa do mesmo processo antes de entrar aqui (nunca chutar URL).
  class Client
    BASE_URL = "https://sistemacal.com.br"
    LOGIN_PATH = "/Account/Login"
    USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) PapyrusPropostas/1.0 (+integracao CAL autorizada)".freeze

    # A sessão do CAL não documenta o próprio tempo de vida — o TTL aqui é conservador de
    # propósito (mais barato relogar cedo demais do que deixar o worker martelar o site com uma
    # sessão morta). Detecta expiração de verdade pelo redirect de volta pro login (#expired?) e
    # reloga sozinho, então o TTL só evita usar uma sessão provavelmente morta sem nem tentar.
    SESSION_TTL = 15.minutes
    SESSION_CACHE_KEY = "cal:session_cookies"

    class AuthenticationError < StandardError; end
    class RequestError < StandardError; end

    def initialize(email: ENV.fetch("CAL_EMAIL", nil), password: ENV.fetch("CAL_PASSWORD", nil))
      raise AuthenticationError, "CAL_EMAIL/CAL_PASSWORD não configurados" if email.blank? || password.blank?

      @email = email
      @password = password
    end

    def self.configured?
      ENV["CAL_EMAIL"].present? && ENV["CAL_PASSWORD"].present?
    end

    # GET autenticado. `path` é relativo (ex.: "/NormaLegalBdCliente").
    def get(path, referer: nil)
      with_session { |cookies| request(:get, path, cookies: cookies, referer: referer) }
    end

    # Baixa um arquivo autenticado (ex.: /UploadArquivo/ObterPdfPorNome?nome=...). O CAL responde
    # com 302 pra uma URL assinada num CDN à parte (files.sistemacal.com.br, com Expires/
    # Signature próprios) — essa segunda etapa não usa cookie nenhum, a assinatura da própria URL
    # já autoriza, então é uma requisição HTTP crua, fora de with_session. Devolve
    # [bytes, content_type] ou nil se o CAL não confirmar o redirect esperado.
    def download(path, referer: nil)
      response = with_session { |cookies| request(:get, path, cookies: cookies, referer: referer) }
      return nil unless response.is_a?(Net::HTTPRedirection)

      file_uri = URI(response["location"])
      file_response = Net::HTTP.get_response(file_uri)
      return nil unless file_response.is_a?(Net::HTTPSuccess)

      [ file_response.body, file_response["content-type"] ]
    end

    # POST de formulário autenticado (application/x-www-form-urlencoded) — é assim que o CAL
    # recebe tanto o login quanto a busca de normas, não tem endpoint JSON.
    def post_form(path, params, referer: nil, extra_headers: {})
      with_session { |cookies| request(:post, path, cookies: cookies, params: params, referer: referer, extra_headers: extra_headers) }
    end

    private

    # Usa a sessão em cache; se a chamada voltar redirecionada pro login (expirou, ou nunca
    # logou), faz login de novo e tenta UMA vez a mais — nunca em loop.
    def with_session
      cookies = cached_cookies || login!
      response = yield(cookies)
      return response unless expired?(response)

      response = yield(login!)
      raise RequestError, "sessão expirou de novo logo após relogar" if expired?(response)

      response
    end

    def expired?(response)
      response.is_a?(Net::HTTPRedirection) && response["location"].to_s.include?(LOGIN_PATH)
    end

    def cached_cookies
      Rails.cache.read(SESSION_CACHE_KEY)
    end

    # Login por formulário: GET na página de login pra pegar o __RequestVerificationToken atual
    # (é de uso único por sessão, nunca fica guardado — ver seção 6 do documento de descoberta),
    # POST das credenciais, e segue os redirects até confirmar que chegou no Dashboard. Grava a
    # sessão resultante no cache pras próximas chamadas não relogarem à toa.
    def login!
      cookies = {}

      login_page = request(:get, LOGIN_PATH, cookies: cookies)
      merge_cookies!(cookies, login_page)
      token = extract_csrf_token(login_page.body)
      raise AuthenticationError, "token CSRF não encontrado na página de login do CAL" if token.blank?

      response = request(:post, LOGIN_PATH, cookies: cookies, referer: "#{BASE_URL}#{LOGIN_PATH}",
        params: { "__RequestVerificationToken" => token, "ReturnUrl" => "/", "Email" => @email, "Password" => @password })
      merge_cookies!(cookies, response)

      response = follow_redirects(response, cookies, referer: "#{BASE_URL}#{LOGIN_PATH}")
      raise AuthenticationError, "CAL não confirmou o login (status #{response.code})" unless response.code.to_i == 200
      raise AuthenticationError, "CAL aceitou a sessão mas a página não é o Dashboard — credenciais certas mas fluxo mudou?" unless response.body.to_s.include?("<title>Dashboard")

      Rails.cache.write(SESSION_CACHE_KEY, cookies, expires_in: SESSION_TTL)
      cookies
    end

    def follow_redirects(response, cookies, referer:, max_redirects: 10)
      count = 0

      while response.is_a?(Net::HTTPRedirection)
        count += 1
        raise RequestError, "CAL redirecionou #{count}+ vezes seguidas — possível loop" if count > max_redirects

        location = response["location"]
        uri = URI.join(BASE_URL, location)
        response = request(:get, uri.request_uri, cookies: cookies, referer: referer)
        merge_cookies!(cookies, response)
        referer = uri.to_s
      end

      response
    end

    def extract_csrf_token(html)
      Nokogiri::HTML(html.to_s).at_css('input[name="__RequestVerificationToken"]')&.[]("value")
    end

    def request(method, path, cookies:, params: nil, referer: nil, extra_headers: {})
      uri = path.start_with?("http") ? URI(path) : URI("#{BASE_URL}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      req = klass.new(uri)
      apply_headers!(req, cookies: cookies, referer: referer, extra: extra_headers)
      req.set_form_data(params) if params

      response = http.request(req)
      merge_cookies!(cookies, response)
      response
    end

    # Accept-Encoding: identity é proposital (ver seção 10 do documento de descoberta) — o CAL
    # comprime com brotli/zstd por padrão, e Net::HTTP não descomprime sozinho; pedir sem
    # compressão evita receber bytes ilegíveis em vez de investir em descompressão manual agora.
    def apply_headers!(req, cookies:, referer:, extra:)
      req["User-Agent"] = USER_AGENT
      req["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
      req["Accept-Language"] = "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7"
      req["Accept-Encoding"] = "identity"
      req["Referer"] = referer if referer
      req["Origin"] = BASE_URL if req.is_a?(Net::HTTP::Post)
      req["Content-Type"] = "application/x-www-form-urlencoded" if req.is_a?(Net::HTTP::Post)
      req["Cookie"] = cookie_header(cookies) unless cookies.empty?
      extra.each { |name, value| req[name] = value }
    end

    def merge_cookies!(cookies, response)
      Array(response.get_fields("Set-Cookie")).each do |set_cookie|
        name, value = set_cookie.split(";").first.to_s.split("=", 2)
        cookies[name] = value if name.present? && value.present?
      end
    end

    def cookie_header(cookies)
      cookies.map { |name, value| "#{name}=#{value}" }.join("; ")
    end
  end
end
