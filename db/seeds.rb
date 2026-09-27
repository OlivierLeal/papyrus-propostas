# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# Catálogo de tipos de estudo. A IA recebe este menu (código + nome + descrição) ao ler o ET/TR
# e devolve o(s) código(s) que se aplicam — ver ProcessEtJob/ProcessTrJob. Uma proposta pode ter
# N tipos, ou nenhum (CLAUDE.md seção 13). A descrição é o que a IA usa pra decidir, então ela
# nomeia a sigla por extenso e diz quando o tipo se aplica.
#
# 2026-09-27: catálogo ampliado a partir do acervo histórico (229 jobs com proposta escrita pela
# Papyrus) e dos achados em que a IA identificou um tipo fora do cadastro (PCA, RAS, RCA, EAI,
# estudos arqueológicos, modelagem sonora). Os números de job nos comentários são exemplos do
# acervo, pra quem for revisar achar referência real.
#
# Idempotente por `code`. Tipo já existente não é sobrescrito (pode ter sido editado em
# Configurações), exceto a descrição provisória do EMI, corrigida abaixo.
[
  # --- Estudos de licenciamento ---
  { code: "eia_rima", name: "EIA-RIMA",
    description: "Estudo de Impacto Ambiental e Relatório de Impacto Ambiental. Exigido para licenciamento de empreendimentos de significativo impacto ambiental." },
  { code: "eia", name: "EIA",
    description: "Estudo de Impacto Ambiental sem o RIMA como produto separado (ou quando o ET pede só o EIA)." },
  { code: "rap", name: "RAP",
    description: "Relatório Ambiental Preliminar. Estudo simplificado usado como alternativa ao EIA-RIMA para empreendimentos de menor impacto." },
  { code: "ras", name: "RAS",
    description: "Relatório Ambiental Simplificado. Licenciamento simplificado de empreendimentos de pequeno potencial de impacto (ex.: job 26039)." },
  { code: "rca", name: "RCA",
    description: "Relatório de Controle Ambiental. Estudo exigido em licenciamento de atividades de impacto moderado, geralmente junto com o PCA." },
  { code: "pca", name: "PCA",
    description: "Plano de Controle Ambiental. Medidas de controle/mitigação do empreendimento; na Bahia acompanha o EMI conforme a Portaria INEMA 11.292/16." },
  { code: "emi", name: "EMI",
    description: "Estudo de Médio Impacto. Estudo exigido pelo INEMA (Portaria 11.292/16) para atividades de médio potencial de impacto na Bahia." },
  { code: "eai", name: "EAI",
    description: "Estudo Ambiental Intermediário. Estudo de porte intermediário exigido por alguns órgãos estaduais/municipais." },
  { code: "epi", name: "EPI",
    description: "Estudo de Pequeno Impacto. Estudo simplificado para atividades de pequeno potencial de impacto (comum em licenciamento municipal/urbanístico)." },
  { code: "ea", name: "Estudo Ambiental (EA)",
    description: "Estudo ambiental genérico pedido pelo órgão sem enquadramento específico (ex.: jobs 24006, 24093, 26050)." },
  { code: "eiv", name: "EIV",
    description: "Estudo de Impacto de Vizinhança. Exigido pelo município (Estatuto da Cidade) para empreendimentos urbanos de impacto." },
  { code: "licenciamento_urbanistico", name: "Licenciamento Urbanístico (LU)",
    description: "Obtenção de Licença Urbanística municipal, com os estudos que a prefeitura exigir (ex.: jobs 24022, 26041, 26089)." },

  # --- Meio biótico / supressão ---
  { code: "asv_amf", name: "ASV/AMF",
    description: "Estudos para Autorização de Supressão de Vegetação e Autorização de Manejo de Fauna (inventário florestal, levantamento e resgate de fauna)." },
  { code: "inventario_florestal", name: "Inventário Florestal",
    description: "Inventário florestal, cubagem, fitossociologia ou levantamento de cobertura vegetal (ex.: jobs 24063, 26036, 26084)." },
  { code: "reposicao_florestal", name: "Reposição/Compensação Florestal",
    description: "Projeto e execução de reposição ou compensação florestal, plantio e monitoramento de plantio (ex.: jobs 24069, 24084, 26069)." },
  { code: "prad", name: "PRAD",
    description: "Plano de Recuperação de Áreas Degradadas, revegetação e recuperação florestal (ex.: jobs 26023, 26037, 24118)." },
  { code: "reserva_legal", name: "Reserva Legal/CAR",
    description: "Delimitação e regularização de Reserva Legal e Cadastro Ambiental Rural." },
  { code: "rppn", name: "RPPN",
    description: "Criação ou regularização de Reserva Particular do Patrimônio Natural." },

  # --- Meio socioeconômico / patrimônio ---
  { code: "estudo_arqueologico", name: "Estudo Arqueológico",
    description: "Estudos e licenciamento arqueológico junto ao IPHAN (avaliação de impacto, prospecção, levantamento pré-leilão)." },
  { code: "ecq", name: "ECQ",
    description: "Estudo do Componente Quilombola. Diagnóstico e avaliação de impacto sobre comunidades quilombolas (ex.: jobs 26025, 25051)." },
  { code: "eci", name: "ECI",
    description: "Estudo do Componente Indígena. Diagnóstico e avaliação de impacto sobre terras e povos indígenas (ex.: job 24104)." },
  { code: "estudo_socioeconomico", name: "Estudo Socioeconômico",
    description: "Diagnóstico socioeconômico, programas sociais e comunicação social (ex.: jobs 24060, 24120, 26061)." },
  { code: "regularizacao_fundiaria", name: "Regularização Fundiária",
    description: "Levantamento e regularização fundiária de áreas do empreendimento (ex.: jobs 24059, 26054, 26070)." },

  # --- Meio físico ---
  { code: "modelagem_sonora", name: "Modelagem Sonora",
    description: "Modelagem acústica/sonora de ruído do empreendimento (ex.: jobs 24015, 26078)." },
  { code: "estudo_hidrico", name: "Estudo Hídrico/Outorga",
    description: "Estudo hidrológico, hidrogeológico, de sedimentos ou caracterização hidrográfica, e pedidos de outorga de uso da água." },

  # --- Planos, programas e gestão ---
  { code: "pba", name: "PBA",
    description: "Plano Básico Ambiental: elaboração e/ou execução dos programas ambientais do empreendimento (ex.: jobs 24071, 24090, 25023)." },
  { code: "pea", name: "PEA",
    description: "Plano de Educação Ambiental. Medida de compensação/condicionante associada a processos de licenciamento." },
  { code: "monitoramento_ambiental", name: "Monitoramento Ambiental",
    description: "Campanhas de monitoramento: ruído, material particulado, qualidade do ar e da água, emissões, fauna e flora." },
  { code: "supervisao_ambiental", name: "Supervisão Ambiental de Obra",
    description: "Supervisão/gestão ambiental de obra (SMA), acompanhamento de supressão e atendimento de condicionantes durante a implantação." },
  { code: "gerenciamento_residuos", name: "Gerenciamento de Resíduos",
    description: "PGRS, PGR ou plano de gerenciamento de resíduos da construção civil (RCC)." },
  { code: "acompanhamento", name: "Acompanhamento",
    # Uma proposta pode não pedir nenhum estudo novo — só assessoria contínua. Não é caso
    # especial no código (CLAUDE.md seção 13).
    description: "Assessoria/monitoramento ambiental contínuo, sem um novo estudo de licenciamento a elaborar." },

  # --- Diagnóstico, relatórios e serviços avulsos ---
  { code: "relatorio_tecnico", name: "Relatório Técnico",
    description: "Relatório técnico ou parecer técnico ambiental de escopo simplificado, sem exigência de EIA-RIMA." },
  { code: "due_diligence", name: "Due Diligence Ambiental",
    description: "Due diligence ambiental (DDA), levantamento de passivos e investigação ambiental de áreas (ex.: jobs 25031, 24110, 25040)." },
  { code: "transferencia_titularidade", name: "Transferência de Titularidade",
    description: "Transferência de titularidade de licenças e autorizações ambientais junto ao órgão." },
  { code: "ctf", name: "CTF",
    description: "Cadastro Técnico Federal (IBAMA) e obrigações associadas." },
  { code: "esg", name: "ESG/ACV",
    description: "Serviços de ESG e Avaliação do Ciclo de Vida." },
  { code: "treinamento", name: "Treinamento/Capacitação",
    description: "Treinamentos, capacitações e seminários ambientais." }
].each do |attrs|
  StudyType.find_or_create_by!(code: attrs[:code]) do |study_type|
    study_type.name = attrs[:name]
    study_type.description = attrs[:description]
  end
end

# EMI nasceu com descrição provisória ("nome por extenso a confirmar"); corrige só se ainda for
# ela — não sobrescreve o que alguém tenha editado em Configurações.
StudyType.where(code: "emi").where("description LIKE ?", "%a confirmar%").update_all(
  description: "Estudo de Médio Impacto. Estudo exigido pelo INEMA (Portaria 11.292/16) para atividades de médio potencial de impacto na Bahia."
)

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

# Equipe real da Papyrus (lista trazida pela empresa em 2026-08). rate_man_hour/rate_daily
# (hora-homem/diária) ainda NÃO têm valor real — a lista não veio com preço — então ficam em 0.00 de propósito (placeholder
# óbvio, nunca um número inventado) até alguém preencher em Configurações > Profissionais. Uma
# proposta cuja precificação inclua algum destes fica com subtotal 0 pra essa linha até lá — falha
# de um jeito visível (preço zerado chama atenção), não silencioso.
#
# always_included: true só em Charlene, Ricardo e Pedro (Diretoria/Coordenação) — entram em toda
# proposta independente do tipo de estudo (ver Proposal#ensure_always_included_lines!). Os demais
# variam conforme o que o ET pedir: a IA escolhe quem entra, o entregável e o esforço de cada um
# a partir deste cadastro (ver Proposal#team_suggestion_prompt).
#
# `specialties` (2026-09, corrigido a partir de Equipe.docx trazido pela Papyrus — relato do
# consultor: "a habilitação/registro tá incompleto" nas propostas geradas) tem dupla função: é o
# texto que alimenta o menu da IA (`team_suggestion_prompt`, "cargo + especialidades") E é o
# que entra na coluna HABILITAÇÃO/REGISTRO da tabela EQUIPE TÉCNICA do `.docx`
# (`Proposal#team_rows_for_docx`, "specialties — registration"). Antes tinha só uma etiqueta curta
# de área de atuação ("Fauna geral", "Segurança do trabalho") — o Equipe.docx real da Papyrus tem
# a formação acadêmica completa (graduação/pós/mestrado/doutorado, um item por frase) por pessoa,
# que é o que de fato sai impresso na proposta. `registration` (CREA/CRBio) já batia com o
# Equipe.docx na maioria dos casos e não mudou.
[
  { name: "Charlene Luz", role: "Diretora de Negócios", registration: "CREA 46778",
    specialties: "Doutora em Gestão Ambiental. Mestre em Engenharia Ambiental Urbana. " \
                 "Pós-Graduada em Engenharia de Segurança do Trabalho. MBA em Auditoria e Gestão " \
                 "Ambiental. Engenheira de Produção Mecânica. Bacharel em Urbanismo. Técnica em " \
                 "Meio Ambiente.",
    always_included: true },
  { name: "Ricardo Hortélio", role: "Diretor Técnico", registration: "CRBio 46177/5-D",
    specialties: "MBA em Auditoria e Gestão Ambiental. Biólogo Sênior. Perito Ambiental.",
    always_included: true },
  # Nota operacional (fora do campo specialties de propósito — ele vai pro .docx impresso, e "só
  # entra em propostas da Região Sul" não é habilitação): Sara só deve ser incluída na equipe de
  # propostas de projetos na Região Sul — hoje isso não é aplicado por código nenhum, é só
  # orientação pro consultor ajustar manualmente na Tela de Precificação quando não se aplicar.
  { name: "Sara Marçal", role: "Diretora Regional – Região Sul", registration: "CREA 76207",
    specialties: "MBA Gestão Estratégica de Projetos. Engenheira de Segurança do Trabalho. " \
                 "Engenheira Ambiental." },
  { name: "Pedro Skinner", role: "Coordenador de Projetos", registration: nil,
    specialties: "Doutor e Mestre em Antropologia. Antropólogo.", always_included: true },
  { name: "Francisco Reis", role: "Biólogo Fauna", registration: nil,
    specialties: "Mestrado em andamento no Programa de Pós-Graduação em Ecologia Humana e " \
                 "Gestão Socioambiental. Curso de extensão em Gestão Ambiental. Pós-graduado em " \
                 "Ecologia e biodiversidade. Pós-graduado em Gestão, auditoria, perícia e " \
                 "licenciamento ambiental. Biólogo." },
  { name: "Yuri Alves Bezerra", role: "Engenheiro de Segurança do Trabalho", registration: nil,
    specialties: "Pós-Graduado em Engenharia de Segurança do Trabalho. Engenheiro de Produção." },
  { name: "Antônio Molina", role: "Assessor Ambiental Sênior", registration: nil,
    specialties: "Assessor Ambiental Sênior." },
  { name: "Melissa Oliveira", role: "Revisora e Formatadora", registration: nil,
    specialties: "Graduanda em Letras em Língua Estrangeira." },
  { name: "Rodrigo Moate", role: "Especialista em Geotecnologias", registration: "CREA 89359",
    specialties: "Especialista em Geotecnologias. Geógrafo." },
  { name: "Elizabeth Seydel", role: "Geógrafa", registration: nil,
    specialties: "Gestão de Projetos. Geotecnologias. Geógrafa." },
  { name: "Carolene Marchant", role: "Apoio Administrativo", registration: nil,
    specialties: "MBA em Consultoria e Auditoria. Administração." },
  { name: "Wlisses Batista", role: "Geólogo", registration: "CREA 271603184-3",
    specialties: "Geólogo." },
  { name: "Máida Cynthia", role: "Engenheira Florestal", registration: nil,
    specialties: "Doutora em Agronomia. Mestre em Ciências Florestais. Engenheira Florestal." },
  { name: "Enée G. Pereira", role: "Bióloga e Espeleóloga", registration: "CREA 85.958/08-D",
    specialties: "Mestre em Ecologia e Biomonitoramento. Especialista em Patrimônio " \
                 "Espeleológico. Bióloga e Espeleóloga." },
  { name: "Ícaro Menezes", role: "Biólogo", registration: nil,
    specialties: "Biólogo. Doutor em Ecologia e Conservação da Biodiversidade." },
  { name: "Igor Silva Andrade", role: "Biólogo", registration: nil,
    specialties: "Biólogo. Mestre em Zoologia." },
  { name: "João Loyola", role: "Técnico em Meio Ambiente", registration: nil,
    specialties: "Mestre em Ecologia e Biomonitoramento. Bacharel em Ciência Biológica. " \
                 "Técnico em Meio Ambiente." },
  { name: "George Lima", role: "Auxiliar Técnico Socioambiental", registration: nil,
    specialties: "Designer. Auxiliar Técnico Socioambiental." },
  { name: "Felipe Salles", role: "Arqueólogo", registration: nil, specialties: "Arqueólogo." },
  { name: "Pedro Andrade", role: "Advogado", registration: nil, specialties: "Advogado." },
  { name: "Camila Barreto Coelho de Andrade", role: "Urbanista", registration: nil,
    specialties: "Urbanista. Auditora Ambiental Especialista em Gestão Ambiental. Msc em " \
                 "Desenvolvimento e Gestão Social." },
  { name: "Caio Almeida", role: "Arquiteto", registration: nil,
    specialties: "Programa de Pós-graduação em Arquitetura e Urbanismo. Arquiteto." },
  { name: "Maria Nogueira", role: "Bióloga", registration: nil,
    specialties: "Especialista em Gerenciamento e Auditoria Ambiental. Zoologia. Bióloga." }
].each do |attrs|
  professional = Professional.find_or_initialize_by(name: attrs[:name])
  professional.role = attrs[:role]
  professional.registration = attrs[:registration]
  professional.specialties = attrs[:specialties]
  professional.always_included = attrs[:always_included] || false
  if professional.new_record?
    professional.rate_man_hour = 0
    professional.rate_daily = 0
    professional.active = true
  end
  professional.save!
end
