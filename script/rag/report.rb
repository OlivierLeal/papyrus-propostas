# Relatório visual da ingestão do acervo — SEM tocar no banco e SEM gerar embedding.
#
#   bin/rails runner script/rag/report.rb --path "/caminho/RAG PAPYRUS" --ocr
#   bin/rails runner script/rag/report.rb --path /caminho --out /tmp/acervo.html
#
# Gera um HTML autocontido para revisar, documento a documento, o que o pipeline entendeu:
# que papel cada arquivo recebeu, como o texto foi cortado em trechos e o que foi marcado como
# sensível. É a etapa de conferência ANTES de qualquer coisa ser persistida ou embedada.

require "optparse"

options = { ocr: false, classify: true, out: Rails.root.join("tmp/acervo_rag.html").to_s }
OptionParser.new do |parser|
  parser.banner = "Uso: bin/rails runner script/rag/report.rb --path PASTA [opções]"
  parser.on("--path PATH", "Pasta do acervo (uma subpasta por job)") { |v| options[:path] = v }
  parser.on("--ocr", "Recupera PDFs escaneados com tesseract (usa cache)") { options[:ocr] = true }
  parser.on("--no-ai", "Classifica papéis só pela heurística de caminho") { options[:classify] = false }
  parser.on("--out FILE", "Arquivo HTML de saída") { |v| options[:out] = v }
  parser.on("-h", "--help") { puts parser; exit }
end.parse!(ARGV)

abort("Informe --path com a pasta do acervo.") if options[:path].blank?

puts "Lendo #{options[:path]}#{' (com OCR)' if options[:ocr]}..."
jobs = Rag::Ingestion.new(path: options[:path], classify: options[:classify], ocr: options[:ocr]).call
abort("Nenhum documento encontrado.") if jobs.empty?

html = Rag::ReportRenderer.new(jobs, source: options[:path]).call
File.write(options[:out], html)

documents = jobs.flat_map(&:documents)
puts "#{jobs.size} jobs, #{documents.size} documentos, #{documents.sum { |d| d.chunks.size }} trechos."
puts "Relatório: #{options[:out]}"
