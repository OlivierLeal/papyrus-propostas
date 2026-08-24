# Remarca os trechos do acervo que se repetem entre jobs — o texto de modelo da proposta.
#
#   bin/rails runner script/rag/boilerplate.rb
#
# Não custa chamada de IA nem gera embedding: é só comparação entre os vetores que já estão no
# banco. O script/rag/index.rb já roda isto no fim de cada indexação; este entrypoint existe para
# aplicar a marcação a um acervo indexado ANTES da calibragem, sem precisar reindexar nada.
#
# Rodar de novo é seguro — a marcação é recalculada do zero a cada execução.

puts Rag::BoilerplateDetector.new.call

marked = HistoricalProposalChunk.where(boilerplate: true)
puts "\n--- seções mais marcadas ---"
marked.group(:section_title).order(count_all: :desc).limit(10).count.each do |section, count|
  puts format("  %3d  %s", count, section.presence || "(sem título)")
end
