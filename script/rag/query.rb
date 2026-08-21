# Busca por similaridade no acervo já indexado — a etapa de validação do RAG.
#
#   bin/rails runner script/rag/query.rb "como descrever o escopo de um EIA-RIMA de eólica"
#   bin/rails runner script/rag/query.rb "exigências do cliente" --roles tr_cliente --limit 8
#
# Serve para julgar a QUALIDADE da recuperação antes de plugar isso no Prompt 2: se o trecho
# certo não aparece aqui, não vai aparecer na geração da proposta.

require "optparse"

options = { limit: Rag::Retriever::DEFAULT_LIMIT, roles: Rag::DocumentClassifier::VOICE_OF_PAPYRUS }
parser = OptionParser.new do |opts|
  opts.banner = "Uso: bin/rails runner script/rag/query.rb \"pergunta\" [opções]"
  opts.on("--roles a,b", Array, "Papéis a considerar (default: voz da Papyrus)") { |v| options[:roles] = v }
  opts.on("--all-roles", "Busca em todos os papéis") { options[:roles] = nil }
  opts.on("--limit N", Integer, "Quantos trechos devolver") { |v| options[:limit] = v }
  opts.on("--client NAME", "Restringe a um cliente") { |v| options[:client] = v }
  opts.on("--sensitive", "Inclui trechos com dado identificável") { options[:sensitive] = true }
end
parser.parse!(ARGV)

query = ARGV.join(" ")
abort(parser.to_s) if query.blank?

hits = Rag::Retriever.new.call(
  query, roles: options[:roles], limit: options[:limit],
  include_sensitive: options[:sensitive].present?, client_name: options[:client]
)

puts "\nBUSCA: #{query}"
puts "papéis: #{options[:roles]&.join(', ') || 'todos'} | #{hits.size} resultados\n\n"
abort("Nada encontrado acima do limiar de similaridade.") if hits.empty?

hits.each_with_index do |hit, index|
  puts "#{'─' * 92}"
  puts format("%d. [%.3f] %s", index + 1, hit.similarity, hit.source)
  puts "   seção: #{hit.section.presence || '(sem seção)'} | papel: #{hit.chunk.role}"
  puts "#{'─' * 92}"
  puts hit.chunk.content.truncate(700).gsub(/^/, "   ")
  puts
end
