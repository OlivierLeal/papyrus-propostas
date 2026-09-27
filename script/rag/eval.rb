# Avaliação do RAG sobre dados REAIS (2026-09-27). Rode depois de mexer em recuperação, chunking,
# modelo de embedding, boilerplate ou precedentes, e compare com a rodada anterior.
#
#   bin/rails runner script/rag/eval.rb
#   bin/rails runner script/rag/eval.rb --queries 20     # limita as buscas reexecutadas
#
# Custo: só embeddings de consulta (centavos). Não chama IA de texto.
#
# O que mede:
#   1. Buscas reais que a IA fez no chat (search_historical_archive), reexecutadas hoje:
#      % vazias, similaridade do 1º resultado, e se um mesmo job domina os resultados.
#   2. "Projetos semelhantes" (Rag::SimilarJobFinder) pra cada proposta do sistema.
#   3. Fichas de precedente (JobPrecedent): cobertura de valor/equipe/horas, e os 3 precedentes
#      que cada proposta do sistema recebe.
args = ARGV.dup
query_limit = args.index("--queries")&.then { |i| args[i + 1].to_i }

embedder = Rag::Embedder.new
retriever = Rag::Retriever.new(embedder: embedder)
tool = SearchHistoricalArchiveTool.new(retriever: retriever)

puts "=" * 80
puts "ACERVO"
puts "  documentos atuais: #{HistoricalProposal.current.count} | jobs: #{HistoricalProposal.current.distinct.count(:job_number)}"
puts "  trechos: #{HistoricalProposalChunk.count} | com vetor: #{HistoricalProposalChunk.embedded.count} | boilerplate: #{HistoricalProposalChunk.where(boilerplate: true).count}"
puts "  fichas de precedente: #{JobPrecedent.group(:status).count}"

puts "\n" + "=" * 80
puts "1. BUSCAS REAIS DO CHAT (reexecutadas agora, com diversificação por job)"
calls = ToolCall.where(name: "search_historical_archive").order(:id).map do |call|
  arguments = call.arguments.is_a?(String) ? (JSON.parse(call.arguments) rescue {}) : call.arguments.to_h
  [ arguments["busca"].to_s, arguments["fonte"] || "papyrus" ]
end.uniq.reject { |query, _| query.blank? }
calls = calls.first(query_limit) if query_limit

empty = 0
top_similarities = []
job_counts = Hash.new(0)
total_results = 0
calls.each do |query, source|
  results = Array(JSON.parse(tool.execute(busca: query, fonte: source))["resultados"])
  empty += 1 if results.empty?
  top_similarities << results.first["similaridade"].to_f if results.any?
  results.each { |result| job_counts[result["referencia"].to_s[/projeto (\S+)/, 1]] += 1 }
  total_results += results.size
end
if calls.any?
  dominant_job, dominant = job_counts.max_by { |_, count| count }
  puts "  buscas: #{calls.size} | vazias: #{empty} (#{(100.0 * empty / calls.size).round}%)"
  puts "  similaridade do 1º resultado: média #{(top_similarities.sum / [ top_similarities.size, 1 ].max).round(3)}, mín #{top_similarities.min&.round(3)}"
  puts "  job mais frequente: #{dominant_job} em #{dominant} de #{total_results} resultados (#{(100.0 * dominant.to_i / [ total_results, 1 ].max).round}%)"
  puts "  jobs distintos nos resultados: #{job_counts.size}"
else
  puts "  (nenhuma busca registrada ainda)"
end

puts "\n" + "=" * 80
puts "2. PROJETOS SEMELHANTES (resumo) E 3. PRECEDENTES, por proposta do sistema"
finder = Rag::SimilarJobFinder.new(retriever: retriever) rescue Rag::SimilarJobFinder.new
precedent_finder = Rag::PrecedentFinder.new(embedder: embedder)
Conversation.joins(:proposal).includes(:study_types).order(:id).each do |conversation|
  descriptor = conversation.service_descriptor
  next if descriptor.blank?

  similar = finder.call(descriptor) rescue []
  precedents = precedent_finder.call(descriptor, limit: 3) rescue []
  puts "\n  ##{conversation.id} #{conversation.client_name} (#{conversation.study_types_label})"
  puts "    semelhantes: #{similar.any? ? similar.map { |m| "#{m.label} [#{m.confidence_label}]" }.join('; ') : 'nenhum'}"
  puts "    precedentes: #{precedents.any? ? precedents.map { |m| "#{m.precedent.job_number} (#{m.similarity})" }.join(', ') : 'nenhum'}"
end

puts "\n" + "=" * 80
puts "4. COBERTURA DAS FICHAS DE PRECEDENTE (status ok)"
ok = JobPrecedent.where(status: "ok")
if ok.any?
  with_value = ok.where.not(total_value: nil).count
  with_hours = ok.to_a.count { |precedent| precedent.total_man_hours.positive? }
  puts "  fichas: #{ok.count} | com valor total: #{with_value} (#{(100.0 * with_value / ok.count).round}%) | com horas por função: #{with_hours} (#{(100.0 * with_hours / ok.count).round}%)"
  puts "  lidas com planilha de precificação: #{ok.where(from_spreadsheet: true).count}"
else
  puts "  nenhuma ficha ainda — rode script/rag/precedents.rb"
end
