# Marca o prompt de sistema (SYSTEM_INSTRUCTIONS + PROPOSAL_CHECKLIST_INSTRUCTIONS) como cacheável
# pro Bedrock em conversas que já existiam ANTES de Conversation#mark_system_instructions_cacheable!
# (2026-09) — sem isso, só conversa NOVA (criada depois do deploy) ganha o cachePoint; uma conversa
# já em andamento continua pagando o prompt de sistema inteiro (~3.800 tokens) do zero em toda
# chamada de IA até ser recriada, mesmo padrão já documentado pro texto do item 12 da checklist
# (CLAUDE.md seção 8, "Efeito colateral achado ao limpar o teste ao vivo").
#
# Idempotente — roda de novo sem duplicar nem corromper nada: `mark_system_instructions_cacheable!`
# sempre sobrescreve o `content_raw` da mensagem mais recente com o array atual (texto + cachePoint).
#
#   bin/rails runner script/backfill_system_instructions_cache.rb

scope = Conversation.joins(:messages).where(messages: { role: "system" }).distinct
total = scope.count
puts "#{total} conversa(s) com prompt de sistema pra marcar como cacheável."

updated = 0
scope.find_each do |conversation|
  conversation.mark_system_instructions_cacheable!
  updated += 1
  print "\r#{updated}/#{total}"
end

puts "\nPronto."
