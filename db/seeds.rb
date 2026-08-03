# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

[
  {
    code: "eia_rima",
    name: "EIA-RIMA",
    description: "Estudo de Impacto Ambiental e Relatório de Impacto Ambiental. Exigido para " \
                  "licenciamento de empreendimentos de significativo impacto ambiental."
  },
  {
    code: "rap",
    name: "RAP",
    description: "Relatório Ambiental Preliminar. Estudo simplificado usado como alternativa ao " \
                  "EIA-RIMA para empreendimentos de menor impacto."
  },
  {
    code: "relatorio_tecnico",
    name: "Relatório Técnico",
    description: "Relatório técnico ambiental de escopo simplificado, sem exigência de EIA-RIMA."
  },
  {
    code: "pea",
    name: "PEA",
    description: "Plano de Educação Ambiental. Medida de compensação/condicionante associada a " \
                  "processos de licenciamento."
  },
  {
    code: "emi",
    name: "EMI",
    # TODO: confirmar com a Papyrus o nome por extenso e a descrição oficial deste tipo de estudo.
    description: "Tipo de estudo utilizado pela Papyrus (nome por extenso a confirmar)."
  }
].each do |attrs|
  StudyType.find_or_create_by!(code: attrs[:code]) do |study_type|
    study_type.name = attrs[:name]
    study_type.description = attrs[:description]
  end
end

[
  {
    email: "admin@papyrus.com",
    name: "Admin",
    password: "papyrus",
    password_confirmation: "papyrus"
  }
].each do |user|
  User.find_or_create_by!(email: user[:email]) do |user|
    user.name = user[:name]
    user.password = user[:password]
    user.password_confirmation = user[:password_confirmation]
  end
end