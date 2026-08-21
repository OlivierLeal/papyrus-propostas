# Indexa o acervo histórico no banco e gera os embeddings (CLAUDE.md seção 11.1).
#
#   bin/rails runner script/rag/index.rb --path "/caminho/RAG PAPYRUS" --ocr
#   bin/rails runner script/rag/index.rb --path /caminho --no-embed   # só grava, sem custo
#
# Idempotente: documento com mesmo SHA256 e mesma versão de pipeline não é reprocessado nem
# re-embedado. Para forçar tudo de novo, suba Rag::Indexer::PIPELINE_VERSION.

require "optparse"

options = { ocr: false, embed: true, classify: true }
OptionParser.new do |parser|
  parser.banner = "Uso: bin/rails runner script/rag/index.rb --path PASTA [opções]"
  parser.on("--path PATH", "Pasta do acervo (uma subpasta por job)") { |v| options[:path] = v }
  parser.on("--ocr", "Recupera PDFs escaneados com tesseract antes de indexar") { options[:ocr] = true }
  parser.on("--no-embed", "Grava os chunks sem gerar embedding (sem custo)") { options[:embed] = false }
  parser.on("--no-ai", "Classifica papéis só pela heurística de caminho") { options[:classify] = false }
  parser.on("-h", "--help") { puts parser; exit }
end.parse!(ARGV)

abort("Informe --path com a pasta do acervo.") if options[:path].blank?

puts "Lendo #{options[:path]}#{' (com OCR)' if options[:ocr]}..."
started = Time.current

jobs = Rag::Ingestion.new(path: options[:path], classify: options[:classify], ocr: options[:ocr]) do |n, total, job|
  puts format("[%2d/%d] %-52s %3d arquivos  (%s decorridos)",
    n, total, job.name.truncate(52), job.items.size,
    ActiveSupport::Duration.build((Time.current - started).round).inspect)
  $stdout.flush
end.call
abort("Nenhum documento encontrado.") if jobs.empty?

puts "#{jobs.size} jobs, #{jobs.sum { |job| job.documents.size }} documentos. Indexando#{' e embedando' if options[:embed]}..."
result = Rag::Indexer.new(embed: options[:embed]).call(jobs)

puts format("\nProcessado em %s", ActiveSupport::Duration.build((Time.current - started).round).inspect)
puts result.to_s
puts "\n--- Índice ---"
puts "  #{HistoricalProposal.count} documentos | #{HistoricalProposalChunk.count} chunks | " \
     "#{HistoricalProposalChunk.embedded.count} com embedding"
HistoricalProposal.group(:role).count.sort_by { |_role, count| -count }.each do |role, count|
  puts format("  %-22s %3d", role, count)
end
