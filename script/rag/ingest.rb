# Ingestão do acervo histórico de propostas para o RAG (CLAUDE.md seção 11.1).
#
#   bin/rails runner script/rag/ingest.rb --path "/caminho/RAG PAPYRUS"
#   bin/rails runner script/rag/ingest.rb --path /caminho --limit 1 --no-ai --out /tmp/preview.json
#
# Por enquanto o script só ANALISA e relata — não escreve no banco nem gera embedding.
# A ideia é rodar isso no acervo real, revisar o JSON de saída (principalmente a classificação
# de papel e o corte por seção) e só então ligar a etapa de embedding.

require "optparse"

options = { limit: nil, out: nil, classify: true, ocr: false }
OptionParser.new do |parser|
  parser.banner = "Uso: bin/rails runner script/rag/ingest.rb --path PASTA [opções]"
  parser.on("--path PATH", "Pasta do acervo (uma subpasta por job)") { |v| options[:path] = v }
  parser.on("--limit N", Integer, "Processa só os N primeiros jobs") { |v| options[:limit] = v }
  parser.on("--no-ai", "Classifica só pela heurística de caminho, sem chamar a IA") { options[:classify] = false }
  parser.on("--ocr", "Reconhece PDFs escaneados com tesseract (~4s por página, com cache)") { options[:ocr] = true }
  parser.on("--out FILE", "Grava o resultado detalhado em JSON") { |v| options[:out] = v }
  parser.on("-h", "--help") { puts parser; exit }
end.parse!(ARGV)

abort("Informe --path com a pasta do acervo.") if options[:path].blank?

jobs = Rag::Ingestion.new(
  path: options[:path], limit: options[:limit], classify: options[:classify], ocr: options[:ocr]
).call
abort("Nenhum documento encontrado em #{options[:path]}") if jobs.empty?

documents = jobs.flat_map(&:documents)
chunks = documents.flat_map(&:chunks)

puts "\n=== ACERVO: #{options[:path]} ==="
puts "#{jobs.size} jobs | #{documents.size} documentos | #{chunks.size} chunks | ~#{chunks.sum(&:estimated_tokens)} tokens"
puts "classificação: #{options[:classify] ? 'IA (1 chamada por job) com heurística de reserva' : 'só heurística'}"

STATUS_LABELS = {
  ok: "texto extraído", ocr: "recuperado por OCR", needs_ocr: "escaneado, precisa de OCR",
  unsupported: "formato não suportado", empty: "sem conteúdo",
  failed: "corrompido ou ilegível"
}.freeze

jobs.each do |job|
  puts "\n" + "=" * 92
  puts "JOB #{job.numero || '?'} — #{job.client_name || job.name}#{" · #{job.subject}" if job.subject}"
  puts "-" * 92

  job.documents.sort_by { |doc| [ doc.role, doc.item.relative_path ] }.each do |doc|
    marks = []
    marks << "SUPERSEDED" if doc.item.superseded
    marks << STATUS_LABELS[doc.status] unless doc.ok?

    puts format("  %-22s %-46s %4d chunks %s",
      doc.role, File.basename(doc.item.relative_path).truncate(46), doc.chunks.size,
      marks.any? ? "[#{marks.join(' · ')}]" : "")
    puts format("  %-22s %-46s erro: %s", "", "", doc.error) if doc.error.present?
  end

  by_role = job.indexable.group_by(&:role).transform_values { |docs| docs.sum { |d| d.chunks.size } }
  puts "  → indexável: #{by_role.map { |role, count| "#{role} #{count}" }.join(' | ').presence || 'nada'}"
end

puts "\n" + "=" * 92
puts "--- Papel dos documentos (todos os jobs) ---"
documents.group_by(&:role).sort_by { |_role, docs| -docs.size }.each do |role, docs|
  from_ai = docs.count { |doc| doc.role_source == :ai }
  puts format("  %-22s %3d docs  %4d chunks  (%d via IA)",
    role, docs.size, docs.sum { |doc| doc.chunks.size }, from_ai)
end

puts "\n--- Situação dos arquivos ---"
documents.group_by(&:status).sort_by { |_s, docs| -docs.size }.each do |status, docs|
  puts format("  %-12s %3d  (%s)", status, docs.size, STATUS_LABELS[status])
end

superseded = documents.count { |doc| doc.item.superseded }
puts "  superseded   #{superseded}  (revisão antiga, fora do índice)" if superseded.positive?

puts "\n--- Sensibilidade (LGPD / seção 5) ---"
puts "  #{chunks.count(&:sensitive)} chunks com dado identificável | " \
     "#{chunks.count(&:contains_pricing)} chunks com valor ou termo de preço"

voice = documents.select { |doc| doc.indexable? && Rag::DocumentClassifier::VOICE_OF_PAPYRUS.include?(doc.role) }
puts "\n--- Voz da Papyrus (o que ensina a IA a escrever) ---"
puts "  #{voice.size} documentos | #{voice.sum { |doc| doc.chunks.size }} chunks | " \
     "~#{voice.sum(&:total_tokens)} tokens"

if options[:out]
  payload = jobs.map do |job|
    job.to_h.merge(documents: job.documents.map { |doc| doc.to_h.merge(item: doc.item.to_h, chunks: doc.chunks.map(&:to_h)) })
  end
  File.write(options[:out], JSON.pretty_generate(payload))
  puts "\nJSON detalhado gravado em #{options[:out]}"
end
