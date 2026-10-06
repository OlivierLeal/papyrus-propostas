# Importa uma pasta de TRs pra biblioteca da Papyrus (ReferenceTerm). Paga IA (1 chamada por arquivo)
# e embedding; arquivo já importado (mesmo SHA256) é pulado.
#
#   bin/rails runner script/reference_terms/import.rb "/caminho/2. TR´s"
path = ARGV.first or abort("Uso: bin/rails runner script/reference_terms/import.rb PASTA")
result = ReferenceTerms::Importer.new(path).call
puts "importados: #{result.imported} · ignorados (não são TR): #{result.ignored} · já existiam: #{result.skipped} · falhas: #{result.failed}"
