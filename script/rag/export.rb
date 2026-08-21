# Exporta o acervo já indexado como SQL, para carregar no banco de produção
# (CLAUDE.md seção 11.1).
#
#   bin/rails runner script/rag/export.rb --out tmp/acervo.sql
#   bin/rails runner script/rag/export.rb --out tmp/acervo.sql.gz --gzip
#   bin/rails runner script/rag/export.rb --out tmp/petrobras.sql --job 25001
#
# Do outro lado:
#   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f acervo.sql
#
# O SQL é idempotente (casa por SHA256 do arquivo), então dá para exportar em partes e
# recarregar quantas vezes precisar sem duplicar nada.

require "optparse"
require "zlib"

options = { out: "tmp/acervo.sql" }
OptionParser.new do |parser|
  parser.banner = "Uso: bin/rails runner script/rag/export.rb [opções]"
  parser.on("--out FILE", "Arquivo de saída (default: tmp/acervo.sql)") { |v| options[:out] = v }
  parser.on("--gzip", "Comprime a saída") { options[:gzip] = true }
  parser.on("--job NUMERO", "Exporta só um job (ex.: 25001)") { |v| options[:job] = v }
  parser.on("--only-embedded", "Ignora documentos sem embedding gerado") { options[:only_embedded] = true }
  parser.on("-h", "--help") { puts parser; exit }
end.parse!(ARGV)

scope = HistoricalProposal.all
scope = scope.where(job_number: options[:job]) if options[:job]
scope = scope.where(id: HistoricalProposalChunk.embedded.select(:historical_proposal_id)) if options[:only_embedded]

abort("Nada a exportar — o índice está vazio. Rode script/rag/index.rb antes.") if scope.none?

path = Rails.root.join(options[:out])
FileUtils.mkdir_p(File.dirname(path))
exporter = Rag::SqlExporter.new(scope: scope)

if options[:gzip]
  Zlib::GzipWriter.open(path) { |gz| exporter.call(gz) }
else
  File.open(path, "w") { |file| exporter.call(file) }
end

chunks = HistoricalProposalChunk.where(historical_proposal: scope)
puts "#{scope.count} documentos | #{chunks.count} trechos | #{chunks.embedded.count} com embedding"
puts "SQL: #{path} (#{ActiveSupport::NumberHelper.number_to_human_size(File.size(path))})"
puts "\nCarregar no destino:"
puts "  psql \"$DATABASE_URL\" -v ON_ERROR_STOP=1 -f #{File.basename(path)}"
