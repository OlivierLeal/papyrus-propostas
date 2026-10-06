require "resolv"

module TermOfReferenceAnnex
  # Baixa o TR achado na internet (link de PDF/Word do site do órgão) depois que o consultor aceitou
  # no card. O link veio de uma busca, então o download é desconfiado: só http(s), nunca endereço
  # interno (rede local/loopback — o servidor não pode virar ponte pra dentro da VPS), no máximo
  # MAX_REDIRECTS redirecionamentos, MAX_BYTES e só PDF/Word.
  class Downloader
    class Error < StandardError; end

    MAX_BYTES = 25.megabytes
    MAX_REDIRECTS = 3
    TIMEOUT = 30
    TYPES = {
      "application/pdf" => ".pdf",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => ".docx",
      "application/msword" => ".doc"
    }.freeze

    USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    Result = Data.define(:io, :filename, :content_type)

    def self.call(url) = new(url).call

    def initialize(url)
      @url = url.to_s.strip
    end

    def call
      uri = URI.parse(@url)
      (MAX_REDIRECTS + 1).times do
        raise Error, "Link inválido (só http/https)." unless uri.is_a?(URI::HTTP) && uri.host.present?

        ensure_public_host!(uri.host)
        response, body = fetch(uri)
        case response
        when Net::HTTPRedirection
          uri = URI.join(uri.to_s, response["location"].to_s)
        when Net::HTTPSuccess
          return result_for(uri, response, body)
        else
          raise Error, "O site respondeu #{response.code} ao baixar o arquivo."
        end
      end
      raise Error, "Redirecionamentos demais."
    rescue URI::InvalidURIError
      raise Error, "Link inválido."
    end

    private

    # Lê o corpo em pedaços pra parar no limite de tamanho sem carregar um arquivo gigante inteiro.
    def fetch(uri)
      body = +""
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        request = Net::HTTP::Get.new(uri)
        # Sites de governo (IBAMA, achado ao vivo) respondem 403 pra quem não parece navegador.
        request["User-Agent"] = USER_AGENT
        request["Accept"] = "application/pdf,application/vnd.openxmlformats-officedocument.wordprocessingml.document,application/msword,*/*;q=0.8"
        http.request(request) do |res|
          next unless res.is_a?(Net::HTTPSuccess)

          res.read_body do |chunk|
            body << chunk
            raise Error, "Arquivo maior que #{MAX_BYTES / 1.megabyte} MB." if body.bytesize > MAX_BYTES
          end
        end
      end
      [ response, body ]
    end

    def result_for(uri, response, body)
      content_type = response["content-type"].to_s.split(";").first.to_s.strip.downcase
      extension = File.extname(uri.path.to_s).downcase
      extension = TYPES[content_type] unless TYPES.value?(extension)
      extension ||= ".pdf" if body.start_with?("%PDF")
      raise Error, "O link não é um PDF nem um arquivo do Word." unless TYPES.value?(extension)
      raise Error, "O arquivo veio vazio." if body.empty?

      name = File.basename(uri.path.to_s, ".*").presence || "termo_de_referencia"
      Result.new(io: StringIO.new(body), filename: "#{name.parameterize.presence || 'termo_de_referencia'}#{extension}",
        content_type: TYPES.key(extension))
    end

    def ensure_public_host!(host)
      addresses = Resolv.getaddresses(host)
      raise Error, "Não consegui resolver o endereço do site." if addresses.empty?

      addresses.each do |address|
        ip = IPAddr.new(address)
        raise Error, "Endereço não permitido." if ip.private? || ip.loopback? || ip.link_local? || address.start_with?("0.")
      end
    end
  end
end
