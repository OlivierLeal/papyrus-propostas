# Exporta as fichas de precedente (JobPrecedent) como SQL pra carregar em produção — mesmo motivo
# do script/rag/export.rb: a extração precisa do acervo montado (planilhas no SSD) e paga IA +
# embedding; faz-se uma vez aqui e leva-se o resultado.
#
#   bin/rails runner script/rag/export_precedents.rb > tmp/precedents.sql
#   (no servidor) psql "$DATABASE_URL" -f precedents.sql
#
# Idempotente: upsert por job_number.
connection = ActiveRecord::Base.connection
columns = %w[job_number client_name year service study_types license_acts enterprise location total_value
  value_notes duration team other_costs pricing_details from_spreadsheet descriptor embedding embedding_model
  source_documents extraction_model status error_message extracted_at]

quote = lambda do |precedent, column|
  value = precedent.public_send(column)
  case column
  when "team", "other_costs", "pricing_details" then connection.quote(value.to_json) + "::jsonb"
  when "study_types", "license_acts", "source_documents" then "ARRAY[#{Array(value).map { connection.quote(_1) }.join(',')}]::varchar[]"
  when "embedding" then value ? connection.quote("[#{value.map { |n| n.round(6) }.join(',')}]") + "::vector" : "NULL"
  else connection.quote(value)
  end
end

puts "BEGIN;"
JobPrecedent.find_each do |precedent|
  values = columns.map { |column| quote.call(precedent, column) }
  updates = (columns - [ "job_number" ]).map { |column| "#{column} = EXCLUDED.#{column}" }.join(", ")
  puts "INSERT INTO job_precedents (#{columns.join(', ')}, created_at, updated_at) VALUES (#{values.join(', ')}, NOW(), NOW()) " \
       "ON CONFLICT (job_number) DO UPDATE SET #{updates}, updated_at = NOW();"
end
puts "COMMIT;"
