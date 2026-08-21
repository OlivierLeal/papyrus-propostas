# Estima tokens e custo de indexar um acervo, ANTES de gastar qualquer coisa
# (CLAUDE.md seção 11.1).
#
#   bin/rails runner script/rag/estimate.rb --path "/media/.../PAPYRUS/2025"
#
# Não chama IA nem gera embedding: extrai o texto localmente (que é de graça), conta os
# trechos que sairiam e projeta o resto. Para os PDFs que precisariam de OCR, usa a média de
# tokens por página medida nos documentos que já passaram por OCR neste banco.

require "optparse"

options = {}
OptionParser.new do |parser|
  parser.banner = "Uso: bin/rails runner script/rag/estimate.rb --path PASTA"
  parser.on("--path PATH", "Pasta do acervo") { |v| options[:path] = v }
  parser.on("--tokens-por-pagina N", Integer, "Sobrescreve a média usada para páginas de OCR") { |v| options[:per_page] = v }
  parser.on("-h", "--help") { puts parser; exit }
end.parse!(ARGV)

abort("Informe --path com a pasta do acervo.") if options[:path].blank?

# Média observada no próprio índice; cai num valor de referência quando ainda não há nada
# indexado com OCR para comparar.
ocr_done = HistoricalProposal.where(status: "ocr")
measured = if ocr_done.sum(:page_count).positive?
  HistoricalProposalChunk.where(historical_proposal: ocr_done).sum(:token_count).fdiv(ocr_done.sum(:page_count)).round
end
per_page = options[:per_page] || measured || 490

puts "Lendo #{options[:path]} (sem IA, sem embedding)..."
jobs = Rag::Ingestion.new(path: options[:path], classify: false, ocr: false).call
documents = jobs.flat_map(&:documents)

extraidos = documents.select(&:indexable?)
pendentes = documents.select { |doc| doc.status == :needs_ocr }
falhos = documents.reject { |doc| doc.indexable? || doc.status == :needs_ocr }

tokens_extraidos = extraidos.sum(&:total_tokens)
paginas_ocr = pendentes.sum(&:page_count)
tokens_ocr = paginas_ocr * per_page
total = tokens_extraidos + tokens_ocr

def milhar(n) = ActiveSupport::NumberHelper.number_to_delimited(n)

puts "\n=== ACERVO ==="
puts format("  %3d jobs | %3d documentos | %s trechos", jobs.size, documents.size, milhar(documents.sum { |d| d.chunks.size }))
puts format("  %3d com texto extraído  -> %11s tokens (contados)", extraidos.size, milhar(tokens_extraidos))
puts format("  %3d precisam de OCR     -> %11s tokens (projetados: %d páginas × %d tok/pág medidos)",
  pendentes.size, milhar(tokens_ocr), paginas_ocr, per_page)
puts format("  %3d fora do índice:", falhos.size)
falhos.group_by(&:status).sort_by { |_s, docs| -docs.size }.each do |status, docs|
  puts format("       %-12s %3d", status, docs.size)
end
puts format("\n  TOTAL A EMBEDAR: %s tokens", milhar(total))

puts "\n=== CUSTO (Bedrock sa-east-1) ==="
# Preços por 1M de tokens. Confira na tabela da AWS antes de tomar decisão de orçamento:
# https://aws.amazon.com/bedrock/pricing/
preco_embed = ENV.fetch("PRECO_EMBED_POR_MTOK", "0.10").to_f
puts format("  embedding (%s): %s tok × US$ %.2f/1M = US$ %.2f",
  Rag::Embedder::MODEL_ID, milhar(total), preco_embed, total / 1_000_000.0 * preco_embed)

# A classificação de papel é 1 chamada por job, com um trecho de cada arquivo no prompt.
# Preços do Claude Haiku 4.5 na tabela da Anthropic; no Bedrock podem diferir.
entrada = jobs.sum do |job|
  job.documents.sum { |doc| [ doc.chunks.first&.char_count.to_i, Rag::DocumentClassifier::SAMPLE_CHARS ].min }
end / 3.8
saida = documents.size * 25  # ~25 tokens por linha de resposta (caminho + papel)
custo_classificacao = (entrada / 1_000_000.0 * 1.0) + (saida / 1_000_000.0 * 5.0)
custo_embedding = total / 1_000_000.0 * preco_embed

puts format("  classificação de papel: %d chamadas (Haiku), ~%s tok entrada + ~%s tok saída = US$ %.2f",
  jobs.size, milhar(entrada.round), milhar(saida), custo_classificacao)
puts format("\n  TOTAL: US$ %.2f", custo_embedding + custo_classificacao)

puts "\n=== TEMPO ==="
puts format("  OCR: %d páginas × ~4s = ~%.1f h (só na primeira vez; fica em cache por SHA256)",
  paginas_ocr, paginas_ocr * 4 / 3600.0)
chamadas = (documents.sum { |d| d.chunks.size } / Rag::Embedder::MAX_TEXTS_PER_CALL.to_f).ceil
puts format("  embedding: %d chamadas de até %d trechos = ~%d min (medido: ~1,5s por chamada)",
  chamadas, Rag::Embedder::MAX_TEXTS_PER_CALL, (chamadas * 1.5 / 60).ceil)
