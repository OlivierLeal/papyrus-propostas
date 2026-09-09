# Importa a malha municipal oficial do IBGE pra dentro de `ibge_municipalities` (CLAUDE.md
# seção 3/11.1). Fonte: as APIs públicas do próprio IBGE, uma por UF (nunca "paises/BR" de uma
# vez só — o país inteiro é uma resposta grande demais pra um único request, e um erro no meio
# faria perder o que já tinha baixado; por UF é upsert idempotente, então rodar de novo só
# retoma).
#
#   bin/rails runner script/geospatial/import_ibge_municipalities.rb
#   bin/rails runner script/geospatial/import_ibge_municipalities.rb --ufs SP,RJ,MG
#
# Duas chamadas por UF, os dois endpoints oficiais do IBGE (nenhum é malha + nome junto):
#   - /api/v3/malhas/estados/{UF}?...&intrarregiao=municipio  → geometria (só "codarea", sem nome)
#   - /api/v1/localidades/estados/{UF}/municipios             → nome + UF (sem geometria)
# `qualidade=minima` na malha é proposital: geometria generalizada, arquivo bem menor — não
# precisamos de precisão de cartografia fina pra "em qual município esse KMZ cai".
require "optparse"
require "net/http"
require "json"

UFS = {
  "AC" => 12, "AL" => 27, "AP" => 16, "AM" => 13, "BA" => 29, "CE" => 23, "DF" => 53,
  "ES" => 32, "GO" => 52, "MA" => 21, "MT" => 51, "MS" => 50, "MG" => 31, "PA" => 15,
  "PB" => 25, "PR" => 41, "PE" => 26, "PI" => 22, "RJ" => 33, "RN" => 24, "RS" => 43,
  "RO" => 11, "RR" => 14, "SC" => 42, "SP" => 35, "SE" => 28, "TO" => 17
}.freeze

FACTORY = RGeo::Geographic.spherical_factory(srid: 4326)

options = { ufs: UFS.keys, sleep: 0.5 }
OptionParser.new do |parser|
  parser.banner = "Uso: bin/rails runner script/geospatial/import_ibge_municipalities.rb [opções]"
  parser.on("--ufs UF,UF,...", Array, "Só estas UFs (default: todas as 27)") { |v| options[:ufs] = v.map(&:upcase) }
  parser.on("--sleep N", Float, "Segundos de pausa entre UFs (default: 0.5)") { |v| options[:sleep] = v }
  parser.on("-h", "--help") { puts parser; exit }
end.parse!(ARGV)

def fetch_json(url)
  response = Net::HTTP.get_response(URI.parse(url))
  raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
end

# GeoJSON manda [lon, lat] por ponto, anel externo primeiro (demais são buracos) — mesma
# convenção que KmzGeometryExtractor já usa pra montar geometria a partir de coordenadas cruas
# (RGeo::GeoJSON não é dependência do projeto, não vale a pena só por isto).
def build_polygon(rings)
  linear_rings = rings.map { |ring| FACTORY.linear_ring(ring.map { |lon, lat| FACTORY.point(lon, lat) }) }
  FACTORY.polygon(linear_rings.first, linear_rings[1..])
end

# A malha "qualidade=minima" devolve Polygon pra município com uma peça só, e MultiPolygon só pra
# quem tem ilha/enclave — a coluna é sempre multi_polygon, então Polygon isolado vira um
# MultiPolygon de 1 elemento.
def build_geometry(feature_geometry)
  case feature_geometry["type"]
  when "Polygon"
    FACTORY.multi_polygon([ build_polygon(feature_geometry["coordinates"]) ])
  when "MultiPolygon"
    FACTORY.multi_polygon(feature_geometry["coordinates"].map { |polygon_coords| build_polygon(polygon_coords) })
  else
    raise "Tipo de geometria inesperado: #{feature_geometry['type']}"
  end
end

total = { created: 0, updated: 0, failed: 0 }
started = Time.current

options[:ufs].each_with_index do |uf, index|
  codigo_uf = UFS.fetch(uf) { abort("UF desconhecida: #{uf}") }
  print format("[%2d/%d] %s ... ", index + 1, options[:ufs].size, uf)
  $stdout.flush

  begin
    nomes = fetch_json("https://servicodados.ibge.gov.br/api/v1/localidades/estados/#{codigo_uf}/municipios")
      .index_by { |m| m["id"].to_s }
    malha = fetch_json("https://servicodados.ibge.gov.br/api/v3/malhas/estados/#{codigo_uf}" \
      "?formato=application/vnd.geo+json&qualidade=minima&intrarregiao=municipio")

    malha["features"].each do |feature|
      code_ibge = feature["properties"]["codarea"]
      nome = nomes.dig(code_ibge, "nome")
      next if nome.blank? # malha e lista de nomes desalinhadas (não deveria acontecer, mas não trava o import inteiro por isso)

      municipio = IbgeMunicipality.find_or_initialize_by(code_ibge: code_ibge)
      is_new = municipio.new_record?
      municipio.name = nome
      municipio.uf = uf
      municipio.geom = build_geometry(feature["geometry"])
      municipio.save!
      total[is_new ? :created : :updated] += 1
    rescue StandardError => e
      Rails.logger.error("import_ibge_municipalities: falhou pra código #{code_ibge} (#{uf}): #{e.message}")
      total[:failed] += 1
    end

    puts "#{malha['features'].size} municípios"
  rescue StandardError => e
    puts "FALHOU (#{e.message})"
    Rails.logger.error("import_ibge_municipalities: UF #{uf} falhou por completo: #{e.message}")
  end

  sleep(options[:sleep]) if index < options[:ufs].size - 1
end

puts format("\n%d criados, %d atualizados, %d falharam — %s decorridos. Total na tabela: %d.",
  total[:created], total[:updated], total[:failed],
  ActiveSupport::Duration.build((Time.current - started).round).inspect, IbgeMunicipality.count)
