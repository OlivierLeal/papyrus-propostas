# Extrai a ficha estruturada (JobPrecedent: serviço, valor, prazo, equipe com horas/diárias) de
# cada job do acervo — ver Rag::PrecedentExtractor. 1 chamada de IA + 1 embedding por job.
#
#   bin/rails runner script/rag/precedents.rb                 # todos os jobs ainda sem ficha
#   bin/rails runner script/rag/precedents.rb --redo          # refaz todos
#   bin/rails runner script/rag/precedents.rb --job 25010     # um job
#   bin/rails runner script/rag/precedents.rb --limit 10      # só os 10 primeiros pendentes
#
# Idempotente por job_number. CUSTA DINHEIRO (IA + embedding): ~233 jobs × ~15 mil tokens de
# entrada — poucos dólares no Haiku. Rode com --limit primeiro e confira as fichas.
args = ARGV.dup
job = args.index("--job")&.then { |i| args[i + 1] }
limit = args.index("--limit")&.then { |i| args[i + 1].to_i }
redo_all = args.include?("--redo")

jobs = HistoricalProposal.current.where(role: Rag::DocumentClassifier::VOICE_OF_PAPYRUS)
  .where.not(job_number: nil).distinct.order(:job_number).pluck(:job_number)
jobs = [ job ] if job
jobs -= JobPrecedent.where(status: %w[ok no_data]).pluck(:job_number) unless redo_all || job
jobs = jobs.first(limit) if limit

puts "#{jobs.size} job(s) a processar"
embedder = Rag::Embedder.new
jobs.each_with_index do |number, index|
  precedent = Rag::PrecedentExtractor.new(number, embedder: embedder).call
  summary = if precedent&.status == "ok"
    "valor #{precedent.total_value || '—'} | #{precedent.team_members.size} na equipe | #{precedent.total_man_hours.round} HH | #{precedent.service.to_s.truncate(70)}"
  else
    "#{precedent&.status}: #{precedent&.error_message}"
  end
  puts format("[%d/%d] %s — %s", index + 1, jobs.size, number, summary)
end
puts "\nfichas: #{JobPrecedent.group(:status).count}"
