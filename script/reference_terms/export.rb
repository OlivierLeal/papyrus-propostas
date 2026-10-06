# Exporta a biblioteca de TRs (ReferenceTerm) como SQL pra carregar em produção — a importação paga
# IA + embedding e precisa dos arquivos da Papyrus; faz-se uma vez aqui e leva-se o resultado. O
# arquivo original vai junto (file_data, bytea em hex): é ele que vira o anexo da proposta.
#
#   bin/rails runner script/reference_terms/export.rb > tmp/reference_terms.sql
#   (no servidor) psql "$DATABASE_URL" -f reference_terms.sql
#
# Idempotente: upsert por sha256 (o conteúdo do arquivo).
connection = ActiveRecord::Base.connection
columns = %w[sha256 status title document_type number organ uf municipality study_types activities summary notes
  source_path filename content_type file_data full_text descriptor embedding embedding_model]

quote = lambda do |term, column|
  value = term.public_send(column)
  case column
  when "study_types" then "ARRAY[#{Array(value).map { connection.quote(_1) }.join(',')}]::varchar[]"
  # Arquivo só dos que estão na biblioteca: o descartado (formulário, lista de espécies) só precisa do
  # registro, pra a importação não gastar IA de novo com ele.
  when "file_data" then value && term.status == "active" ? "decode('#{value.unpack1('H*')}', 'hex')" : "NULL"
  when "embedding" then value ? connection.quote("[#{value.map { |n| n.round(6) }.join(',')}]") + "::vector" : "NULL"
  else connection.quote(value)
  end
end

puts "BEGIN;"
ReferenceTerm.order(:id).find_each do |term|
  values = columns.map { |column| quote.call(term, column) }
  updates = (columns - [ "sha256" ]).map { |column| "#{column} = EXCLUDED.#{column}" }.join(", ")
  puts "INSERT INTO reference_terms (#{columns.join(', ')}, created_at, updated_at) VALUES (#{values.join(', ')}, NOW(), NOW()) " \
       "ON CONFLICT (sha256) DO UPDATE SET #{updates}, updated_at = NOW();"
end
puts "COMMIT;"
