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
    email_address: "admin@papyrus.com",
    name: "Admin",
    password: "papyrus",
    password_confirmation: "papyrus"
  }
].each do |attrs|
  user = User.find_or_initialize_by(email_address: attrs[:email_address])

  if user.new_record?
    user.name = attrs[:name]
    user.password = attrs[:password]
    user.password_confirmation = attrs[:password_confirmation]
    user.save!
  end
end

# Equipe real da Papyrus (lista trazida pela empresa em 2026-08). rate_office/rate_field ainda
# NÃO têm valor real — a lista não veio com diária — então ficam em 0.00 de propósito (placeholder
# óbvio, nunca um número inventado) até alguém preencher em Configurações > Profissionais. Uma
# proposta cuja precificação inclua algum destes fica com subtotal 0 pra essa linha até lá — falha
# de um jeito visível (preço zerado chama atenção), não silencioso.
#
# always_included: true só em Charlene, Ricardo e Pedro (Diretoria/Coordenação) — entram em toda
# proposta independente do tipo de estudo (ver Proposal#ensure_always_included_lines!). Os demais
# variam conforme o que o ET pedir; a IA decide horas reais vs. 0 pra cada um (ver
# Proposal#suggestion_prompt), restrita ao menu de study_templates abaixo.
[
  { name: "Charlene Luz", role: "Diretora de Negócios", registration: "CREA 46778",
    specialties: "Direção de negócios", always_included: true },
  { name: "Ricardo Hortélio", role: "Diretor Técnico", registration: "CRBio 46177/5-D",
    specialties: "Direção técnica", always_included: true },
  { name: "Sara Marçal", role: "Diretora Regional – Região Sul", registration: "CREA 76207",
    specialties: "Só entra em propostas de projetos na Região Sul" },
  { name: "Pedro Skinner", role: "Coordenador de Projetos", registration: nil,
    specialties: "Antropologia — coordenação e gestão do projeto", always_included: true },
  { name: "Francisco Reis", role: "Biólogo Fauna", registration: nil, specialties: "Fauna geral" },
  { name: "Yuri Alves Bezerra", role: "Engenheiro de Segurança do Trabalho", registration: nil,
    specialties: "Segurança do trabalho" },
  { name: "Antônio Molina", role: "Assessor Ambiental Sênior", registration: nil,
    specialties: "Assessoria ambiental estratégica" },
  { name: "Melissa Oliveira", role: "Revisora e Formatadora", registration: nil,
    specialties: "Revisão ortográfica e formatação" },
  { name: "Rodrigo Moate", role: "Especialista em Geotecnologias", registration: "CREA 89359",
    specialties: "Geoprocessamento" },
  { name: "Elizabeth Seydel", role: "Geógrafa", registration: nil,
    specialties: "Geoprocessamento e gestão de projetos" },
  { name: "Carolene Marchant", role: "Apoio Administrativo", registration: nil, specialties: nil },
  { name: "Wlisses Batista", role: "Geólogo", registration: "CREA 271603184-3",
    specialties: "Meio físico" },
  { name: "Máida Cynthia", role: "Engenheira Florestal", registration: nil, specialties: "Flora" },
  { name: "Enée G. Pereira", role: "Bióloga e Espeleóloga", registration: "CREA 85.958/08-D",
    specialties: "Quiróptero e mastofauna" },
  { name: "Ícaro Menezes", role: "Biólogo", registration: nil, specialties: "Avifauna" },
  { name: "Igor Silva Andrade", role: "Biólogo", registration: nil, specialties: "Herpetofauna" },
  { name: "João Loyola", role: "Técnico em Meio Ambiente", registration: nil,
    specialties: "Meio socioeconômico" },
  { name: "George Lima", role: "Auxiliar Técnico Socioambiental", registration: nil,
    specialties: "Design — apoio ao meio socioeconômico" },
  { name: "Felipe Salles", role: "Arqueólogo", registration: nil, specialties: nil },
  { name: "Pedro Andrade", role: "Advogado", registration: nil, specialties: "Análise jurídica" },
  { name: "Camila Barreto Coelho de Andrade", role: "Urbanista", registration: nil,
    specialties: "Auditoria ambiental e gestão social" },
  { name: "Caio Almeida", role: "Arquiteto", registration: nil, specialties: nil },
  { name: "Maria Nogueira", role: "Bióloga", registration: nil,
    specialties: "Zoologia — gerenciamento e auditoria ambiental" }
].each do |attrs|
  Professional.find_or_create_by!(name: attrs[:name]) do |professional|
    professional.role = attrs[:role]
    professional.registration = attrs[:registration]
    professional.specialties = attrs[:specialties]
    professional.rate_office = 0
    professional.rate_field = 0
    professional.active = true
    professional.always_included = attrs[:always_included] || false
  end
end

# Menu inicial de equipe para EIA-RIMA (o tipo de estudo mais completo, e o que a própria lista da
# Papyrus descreve — meio físico + flora + fauna por grupo + socioeconomia + arqueologia). Os
# outros study_types (RAP, Relatório Técnico, PEA, EMI) ficam SEM template por enquanto: qual
# subconjunto desta equipe atende cada um é uma decisão de prática da Papyrus que não dá pra
# adivinhar aqui — sem isso, a IA simplesmente não tem esses profissionais no menu pra sugerir
# nesses tipos de estudo, até alguém completar via Configurações > Profissionais/Templates.
# hours_office_default/hours_field_default em 0 pelo mesmo motivo das taxas: nenhum número real
# de horas foi informado, e 0 é o placeholder que já é o default da coluna.
if (eia_rima = StudyType.find_by(code: "eia_rima"))
  [
    { professional: "Charlene Luz", deliverable: "Direção de Negócios" },
    { professional: "Ricardo Hortélio", deliverable: "Direção Técnica" },
    { professional: "Sara Marçal", deliverable: "Direção Regional — Região Sul" },
    { professional: "Pedro Skinner", deliverable: "Coordenação e Gestão do Projeto" },
    { professional: "Francisco Reis", deliverable: "Diagnóstico de Fauna — Geral" },
    { professional: "Yuri Alves Bezerra", deliverable: "Segurança do Trabalho" },
    { professional: "Antônio Molina", deliverable: "Assessoria Ambiental Estratégica" },
    { professional: "Melissa Oliveira", deliverable: "Revisão e Formatação" },
    { professional: "Rodrigo Moate", deliverable: "Geoprocessamento e Cartografia" },
    { professional: "Elizabeth Seydel", deliverable: "Geoprocessamento e Cartografia" },
    { professional: "Carolene Marchant", deliverable: "Apoio Administrativo" },
    { professional: "Wlisses Batista", deliverable: "Diagnóstico de Meio Físico" },
    { professional: "Máida Cynthia", deliverable: "Diagnóstico de Flora" },
    { professional: "Enée G. Pereira", deliverable: "Diagnóstico de Fauna — Quiróptero e Mastofauna" },
    { professional: "Ícaro Menezes", deliverable: "Diagnóstico de Fauna — Avifauna" },
    { professional: "Igor Silva Andrade", deliverable: "Diagnóstico de Fauna — Herpetofauna" },
    { professional: "João Loyola", deliverable: "Diagnóstico Socioeconômico" },
    { professional: "George Lima", deliverable: "Apoio ao Diagnóstico Socioeconômico" },
    { professional: "Felipe Salles", deliverable: "Diagnóstico de Arqueologia" },
    { professional: "Pedro Andrade", deliverable: "Análise Jurídica" },
    { professional: "Camila Barreto Coelho de Andrade", deliverable: "Análise Urbanística" },
    { professional: "Caio Almeida", deliverable: "Apoio de Arquitetura" },
    { professional: "Maria Nogueira", deliverable: "Apoio ao Diagnóstico de Fauna" }
  ].each do |attrs|
    professional = Professional.find_by!(name: attrs[:professional])
    StudyTemplate.find_or_create_by!(study_type: eia_rima, professional: professional, deliverable_name: attrs[:deliverable]) do |template|
      template.hours_office_default = 0
      template.hours_field_default = 0
    end
  end
end
