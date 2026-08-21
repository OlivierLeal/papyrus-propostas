# Papyrus Propostas

Sistema para automatizar a geração de **Propostas Técnicas e Comerciais** da Papyrus Consultoria Ambiental. O consultor sobe um Termo de Referência (TR), um arquivo KMZ e documentos complementares; o sistema processa tudo (IA + geoespacial), o consultor revisa e ajusta via chat, aprova o preço e recebe um PDF pronto no padrão visual da Papyrus.

Este documento é a fonte de verdade do escopo. Foi consolidado a partir de dois documentos-fonte que descrevem o projeto em estágios diferentes:

- `../Proposta Papyrus IA.pdf` — proposta comercial original (125h, R$15.000, abril/2026). Descreve uma versão mais simples, baseada em chat puro.
- `../sistema-papyrus-diagramas.html` — estudo de arquitetura posterior (v1.0), com um desenho bem mais robusto (tela de setup, jobs em background, motor de precificação auditável, PostGIS com bases oficiais reais).

**Decisão tomada:** construir a versão do HTML (arquitetura completa). O PDF fica só como referência histórica do escopo comercial original — os valores de horas/R$ nele **não** valem mais para este escopo.

---

## 1. Conceito central

Duas camadas de inteligência separadas por design:

1. **IA (Claude API)** lê os documentos e decide o *conteúdo*: tipo de licença, tipo de estudo, órgão ambiental, diagnósticos, equipe sugerida, texto das seções da proposta.
2. **Motor de precificação determinístico** (código Ruby, não IA) calcula o *preço*: horas × taxa × BDI × impostos + logística + custos externos. Auditável linha a linha, sem "alucinação" de valores.

A IA nunca faz conta de dinheiro. Ela só identifica escopo; quem precifica é o motor.

---

## 2. Fluxo do usuário (jornada completa)

1. Consultor faz login.
2. Clica em "Nova Proposta" → **Tela de Setup**: informa nome do cliente e tipo de estudo, sobe o TR (PDF/DOCX), sobe o KMZ, adiciona documentos complementares (opcional).
3. Revisa os arquivos na tela de setup e confirma ("Gerar Proposta").
4. **Processamento em background** (paralelo, via jobs):
   - IA analisa o TR.
   - Módulo geoespacial processa o KMZ.
   - IA lê os documentos complementares.
5. Sistema apresenta um **resumo estruturado** na Tela de Resultado (via WebSocket/Action Cable, com progresso em tempo real).
6. Consultor revisa o resumo; pode corrigir via chat (loop: ajustar → revisar até aprovar).
7. Abre a **Tela de Precificação**: sistema carrega o template de horas do tipo de estudo, consultor ajusta horas se necessário, sistema recalcula o preço automaticamente em tempo real.
8. Preço aprovado → solicita geração do PDF.
9. IA escreve o texto das seções; o backend monta o PDF no layout padrão Papyrus.
10. PDF pronto para download; proposta salva no histórico (arquivos + PDF + conversa completos).

Documentos complementares podem ser enviados a qualquer momento da conversa, não só no início.

---

## 3. Arquitetura técnica

| Componente | Tecnologia |
|---|---|
| Framework | Ruby on Rails 8+ |
| Frontend | Hotwire (Turbo + Stimulus), Tailwind CSS |
| Autenticação | Gerador nativo do Rails 8 (`rails generate authentication`) — e-mail/senha simples, sem Devise |
| Background jobs | Solid Queue (substitui Sidekiq do diagrama original — mesma função, sem dependência de Redis) |
| WebSockets | Action Cable via Solid Cable |
| Banco de dados | PostgreSQL + extensão PostGIS |
| Armazenamento | Active Storage (local na VPS ou bucket externo), arquivos criptografados |
| IA / LLM | Claude API (Anthropic) via gem `ruby_llm` — lê PDF/DOCX nativamente |
| Geoespacial | RGeo + GDAL para parsing de KMZ/KML e cálculos; PostGIS para queries de sobreposição |
| Mapas | Mapbox Static API — gera imagem estática do polígono para inserir no PDF |
| Hospedagem | Stay22 API (`api.stay22.com/v2/accommodations`) — busca opções de acomodação pelo município identificado no TR; consultor escolhe a melhor opção no chat (ver seção 5) |
| Geração de documento | **DOCX** (não PDF — decisão revista), preenchendo um modelo `.docx` real da Papyrus via manipulação direta do XML interno (gem `rubyzip`, já dependência do projeto pelo KMZ) — ver seção 8 |
| Infra | VPS (Hostinger), deploy via Kamal ou Docker, CI/CD via GitHub Actions |

### Camadas geoespaciais de referência (importadas via shapefile para PostGIS)

- `ibge_municipalities` — polígonos dos 5.570 municípios (IBGE)
- `mata_atlantica_layer` — bioma Mata Atlântica (Lei 11.428/2006)
- `conservation_units` — Unidades de Conservação (ICMBio, ~2.000 polígonos)
- `indigenous_lands` — Terras Indígenas (FUNAI, ~600 polígonos)
- `quilombos_layer` — Territórios Quilombolas (INCRA)
- `watersheds_layer` — Bacias Hidrográficas (ANA)

### Mapeamento estado → órgão ambiental (automático, a partir do município identificado)

RS→FEPAM, RJ→INEA, SC→IMA, BA→INEMA, SP→CETESB, MG→SEMAD/SUPRAM, outros/federal→IBAMA.

---

## 4. Modelo de dados (visão geral)

**Núcleo da conversa** (via gem `ruby_llm` — `acts_as_chat`/`acts_as_message`, ver seção 12):
- `users` — id, email, name, role, password_digest
- `conversations` — `acts_as_chat`; colunas de domínio: user_id, client_name, status, study_type_id, setup_completed_at (colunas nativas da gem: model_id)
- `messages` — `acts_as_message`; colunas nativas da gem: conversation_id, role, content, content_raw, tokens de entrada/saída/cache. Anexos (TR, KMZ, complementares) via Active Storage nativo (`has_many_attached :attachments`), **não** uma tabela `attachments` própria — o upload na Tela de Setup é a primeira mensagem do usuário na conversa, já com os arquivos anexados
- `tool_calls` / `models` — tabelas nativas da gem (function-calling e registro de modelos LLM com pricing/capabilities); não fazem parte do domínio, mas ficam disponíveis para uso futuro (ex.: extração estruturada de dados do TR)

**Proposta e precificação (implementado):**
- `proposals` — conversation_id, content_json, pdf_url, version, status (`draft`/`priced`/`approved`)
- `project_pricings` — proposal_id, bdi, tax_multiplier, distance_km, logistics_days, rental_per_day, meal_per_day, fuel_total, external_costs (jsonb, `[{description, value}]`), payment_schedule (jsonb, default 30/60/5/5), total_value. Os parâmetros de logística (aluguel, alimentação, combustível) são campos diretos aqui — **não existe mais uma tabela `logistics_configs`** (removida; ver seção 5).
- `proposal_professionals` — project_pricing_id, professional_id, deliverable_name, hours_office, hours_field, subtotal

**Configuração (admin, não muda por proposta):**
- `professionals` — name, role, rate_office, rate_field, registration, specialties, active
- `study_types` — name, code, description (EIA-RIMA, EMI, Relatório Técnico, PEA, RAP...)
- `study_templates` — study_type_id, professional_id, deliverable_name, hours_office_default, hours_field_default (horas padrão copiadas para `proposal_professionals` no início; a taxa vem sempre atualizada de `professionals`)

**Geoespacial:**
- `geospatial_results` — conversation_id, area_ha, perimeter_km, municipalities (jsonb), mata_atlantica (bool), unidade_conservacao (bool), terra_indigena (bool), quilombo (bool), watershed, map_image_url, polygon (geometry, PostGIS)

Relacionamentos principais: `users` 1—N `conversations`; `conversations` 1—N `messages`/`attachments`, 1—1 `geospatial_results`, 1—N `proposals`; `proposals` 1—1 `project_pricings`; `project_pricings` 1—N `proposal_professionals`.

---

## 5. Motor de precificação (detalhado, implementado)

Entradas: tipo de estudo (confirmado pela IA), municípios/distância logística, sobreposições geoespaciais.

1. **Composição da equipe**: ao avançar da revisão para a precificação (`Proposal#build_with_ai_suggested_team!`), a IA sugere horas por profissional/entregável com base em tudo que já foi extraído do TR e dos documentos complementares nesta conversa (ver `conversation.ask_internally`). A sugestão é **sempre restrita ao "menu"** de profissionais × entregáveis já cadastrados em `study_templates` para o tipo de estudo — a IA nunca inventa um `professional_id` ou `deliverable_name` novo; qualquer linha sugerida que não bata exatamente (por id + nome normalizado) com uma linha do menu é descartada. Se a chamada à IA falhar ou não retornar nenhuma linha válida, o sistema cai automaticamente no fallback determinístico `Proposal#build_from_template!`, que copia as horas padrão (`hours_office_default`/`hours_field_default`) direto do template.
2. **Ajuste manual**: grade editável na Tela de Precificação (`proposals#show`/`#update`) — Profissional × Entregável × Horas escritório/campo, mais adição/remoção de linhas fora do menu sugerido (`proposal_professionals#create`/`#destroy`). Recalcula ao submeter o formulário.
3. **Cálculo** (`ProjectPricing#recalculate!` / `ProposalProfessional#recalculate_subtotal`):
   - `C1` = horas escritório × taxa escritório
   - `C2` = horas campo × taxa campo
   - `C3` = subtotal profissional = (C1 + C2) × BDI × impostos
   - `C4` = logística = (aluguel/dia + alimentação/dia) × dias de campo + combustível total
   - `C5` = custos externos (ARTs, terceiros: fauna, flora, drone) — lançados manualmente por proposta em `external_costs` (jsonb)
   - `C6` = TOTAL = Σ profissionais + logística + externos
4. Parâmetros do sistema: tabela de profissionais com taxa/dia por escritório e campo (`professionals`); BDI e impostos (`tax_multiplier`) editáveis por proposta em `project_pricings` (defaults 1.20/1.25). **Não existe mais uma tabela de configuração de logística** (`logistics_configs` foi removida) — aluguel/dia, alimentação/dia, combustível total e dias de campo são campos digitados direto na Tela de Precificação por proposta.
5. **Hospedagem**: não entra no cálculo automático. O sistema consulta a API do Stay22 usando o município identificado no TR e apresenta as opções de acomodação como mensagem no chat; o consultor escolhe a melhor opção manualmente. Por enquanto isso fica só registrado na conversa (informativo) — pendente da chave de API do Stay22.
6. Saídas: tabela de preço auditável por linha, cronograma de desembolso por parcelas (`payment_schedule_amounts`, default 30/60/5/5), dados prontos para o PDF. Proposta só é editável enquanto `status != "approved"`; aprovar (`proposals#approve`) trava os campos e conclui a conversa.

---

## 6. Pipeline de processamento de dados

Após confirmação na tela de setup, arquivos vão para Active Storage (criptografado) e disparam 3 jobs em paralelo:

- **ProcessTR**: extração de texto (ou envio nativo do PDF/DOCX pra Claude) → IA identifica tipo de licença, tipo de estudo, órgão ambiental, municípios, diagnósticos, condicionantes, ressalvas. Ao concluir, dispara a busca de hospedagem (Stay22) usando o município identificado.
- **ProcessKMZ**: descomprime → parseia XML/KML (Nokogiri) → extrai coordenadas → RGeo calcula área (ha), perímetro (km), centroide → PostGIS cruza com as 6 camadas de referência → gera imagem do mapa (Mapbox Static API, bounding box + margem 20%).
- **ProcessCompDocs**: IA identifica tipo de cada documento complementar e extrai escopos anteriores, preços de referência, condicionantes, metodologias, equipes usadas.

Um 4º job (**GenerateSummary**) só dispara quando os três anteriores terminam, e monta o resumo estruturado exibido na Tela de Resultado via WebSocket.

**Ponto de atenção:** TRs grandes (100+ páginas) com muitos complementares podem levar 60–120s para processar — feedback visual (barra de progresso por etapa) é essencial.

---

## 7. Documentos complementares — o que a IA deve extrair

Tipos aceitos: propostas anteriores semelhantes, resoluções/normas específicas, projetos básicos do empreendimento, relatórios ambientais anteriores, condicionantes de licenças anteriores, atas de reunião com órgão licenciador, mapas/plantas, estudos técnicos prévios, comunicados/ofícios INEMA/IBAMA.

Regras:
- Proposta anterior como referência → reutilizar estrutura de escopo, padrão de preço, equipe utilizada, ressalvas aplicadas, metodologias descritas.
- Resoluções/normas → incorporar nas referências legais e ajustar escopo conforme exigências.
- Condicionantes de licenças anteriores → identificar e sinalizar impacto em escopo/preço.
- Projeto básico → extrair tipo de empreendimento, capacidade/potência, infraestrutura prevista.
- Sempre informar ao usuário quais informações foram extraídas de cada documento, para validação.
- Se um complementar conflitar com o TR, sinalizar a divergência e pedir orientação ao usuário (nunca decidir sozinho).

---

## 8. Geração do documento (DOCX — decisão revista, era PDF)

**Mudança de escopo:** o desenho original (seção histórica) previa PDF via Grover/Chrome headless.
A Papyrus decidiu que o formato final precisa ser **DOCX**, preenchendo um modelo `.docx` real
deles (com a identidade visual já aplicada) em vez de recriar o layout em HTML/CSS.

Processo em duas etapas, com responsabilidades separadas (princípio mantido):

1. A IA produz um **texto estruturado** com todo o conteúdo (seções, dados, escopo, equipe, valores), guiada pelo "Prompt de Geração de Proposta" (seção 9), incluindo se o TR exige apresentação em documentos/envelopes separados (técnico × comercial).
2. O backend Rails preenche o(s) modelo(s) `.docx` da Papyrus com esse conteúdo — abrindo o arquivo (é um zip com XML dentro), substituindo marcadores de texto no `word/document.xml` via `rubyzip`, e re-empacotando. **Não é a IA que mexe no arquivo** — ela só gera o texto que entra nos marcadores.

O layout visual (fontes, cores, margens, logotipos, tabelas) vem pronto do modelo `.docx` da Papyrus — o código só substitui conteúdo, nunca redesenha layout. Isso garante consistência visual entre propostas independente do conteúdo gerado.

**Técnica × Comercial separadas ou juntas:** a IA lê o TR e sinaliza se ele exige documentos/envelopes
separados (comum em licitação pública). O consultor vê essa sugestão na Tela de Precificação/Aprovação
e pode trocar antes de gerar. Conforme a escolha, o sistema gera 1 arquivo (`.docx` único) ou 2
(`proposta_tecnica.docx` + `proposta_comercial.docx`), a partir de modelos `.docx` correspondentes.

O usuário pode pedir ajustes de conteúdo via chat a qualquer momento; a IA gera novo texto estruturado e o backend remonta o(s) DOCX (nova versão).

---

## 9. Prompts do sistema (2 prompts principais)

**Prompt 1 — Sistema (contexto fixo):** dados fixos da Papyrus — razão social, CNPJ, endereço, dados bancários, texto institucional, lista de profissionais (nome, formação, registro, área de atuação), tabela de preços base, marcos de desembolso padrão (ex.: 30% assinatura, 60% protocolo, 5% vistoria, 5% emissão), regras de negócio (quando muda tipo de estudo, o que vira proposta complementar), nomes/cargos dos diretores que assinam. Atualizado manualmente quando necessário — **não deve ir para tabelas de cadastro nesta versão**, fica no prompt.

**Prompt 2 — Geração de Proposta:** instrui a IA sobre como estruturar o conteúdo — quais seções gerar, como organizar os dados, quais campos preencher. Retorna texto estruturado que o backend usa para montar o PDF.

---

## 10. Requisitos não-funcionais

- Processamento do TR: até 120s (documentos até 100 páginas).
- Processamento do KMZ: até 30s.
- Geração do PDF final: até 60s.
- Suporte a até 5 usuários simultâneos (fase inicial).
- TLS 1.3 em trânsito; arquivos armazenados (TR, KMZ, PDFs) criptografados.
- Conformidade com LGPD.
- Backups diários automáticos, retenção de 30 dias.
- Disponibilidade mínima 99% (SLA).
- Bases geoespaciais devem ser atualizáveis sem downtime.

---

## 11. Fora de escopo (evoluções futuras, não implementar agora)

- Telas de cadastro web para empresa/equipe/parâmetros comerciais (hoje isso fica nos prompts/seeds).
- Gestão de múltiplos perfis de usuário com permissões diferenciadas.
- Dashboard com métricas e relatórios de propostas.
- Mapa interativo com visualização de sobreposição (SIG Web).
- Controle avançado de revisões com numeração automática.

### 11.1. RAG e memória por cliente (avaliado a partir de estudo de arquitetura trazido pela Papyrus)

A Papyrus trouxe um estudo propondo uma arquitetura de "motor de composição de propostas" com RAG (`pgvector`), memória por cliente com confiança/rastreabilidade, e aprendizado a partir de edições humanas. Avaliação: os princípios centrais (LLM não calcula preço, LLM não é a fonte de verdade dos dados, regras determinísticas validam a sugestão da IA) **já são o que este projeto faz desde a seção 1** — não é novidade, é confirmação do desenho atual.

O que é valioso mas depende de pré-requisitos que ainda não existem, nesta ordem:

1. ~~Motor de precificação determinístico (seção 5)~~ — **implementado**: `Proposal`/`ProjectPricing`/`ProposalProfessional`, com sugestão de equipe pela IA restrita ao menu de `study_templates` e Tela de Precificação editável.
2. Retomada do módulo geoespacial (KMZ/PostGIS), hoje pausado.
3. ~~**RAG com `pgvector`** (acervo histórico da Papyrus)~~ — **implementado** (fase 1):
   - Pipeline em `app/services/rag/` + entrypoints em `script/rag/`. O acervo é uma pasta por
     **job** (`25001_Petrobras_Cetaceos`), e dentro dela convivem papéis diferentes: a proposta
     que a Papyrus escreveu, o TR e os anexos do cliente, minutas contratuais, planilhas de
     custo e revisões velhas. `Rag::DocumentClassifier` separa por papel com **1 chamada de IA
     por job**, restrita a um menu fechado (`ROLES`), usando a estrutura de pastas apenas como
     sinal — no acervo real ela é inconsistente (`Docs Papyrus` × `Doc´s Papyrus`).
   - **Só `proposta_papyrus` e `planilha_papyrus` são "voz da Papyrus"** (o que ensina a IA a
     escrever). O documento do cliente costuma ser maior que a proposta; misturados no mesmo
     índice, o RAG ensinaria a IA a imitar o cliente. `tr_papyrus` (TR que a Papyrus escreve
     para subcontratar) fica indexado mas fora da voz — é outra estrutura de documento.
   - Extração: PDF via `pdftotext`, DOCX via Nokogiri (títulos vêm do **estilo** do parágrafo,
     porque a numeração do Word é automática e não está no texto), `.doc` via LibreOffice, e
     **OCR** (`pdftoppm` + `tesseract`, com cache por SHA256) para os PDFs rasterizados, que são
     boa parte do acervo. Chunking por seção, com teto de 1800 caracteres — acima disso o
     `cohere.embed-multilingual-v3` trunca sem avisar.
   - Embeddings no **Bedrock sa-east-1** (`Rag::Embedder`, SigV4 na mão: o `ruby_llm` não tem
     provider de embedding para Bedrock). O `embed-v4` só roda em perfil `global`, que faz
     roteamento cross-region — como o acervo tem cliente, CNPJ e preço, o dado fica no Brasil.
   - Uso pela IA, em duas frentes:
     - **Proativa**: `GenerateSummaryJob` roda `Rag::SimilarJobFinder` sobre o que foi extraído
       do TR e informa no resumo quais projetos anteriores se parecem com este ("25001 ·
       Petrobras · Cetáceos — 71%"). É o caso real do consultor: mesmo serviço, outra área — a
       proposta antiga é o melhor ponto de partida, e não adianta ela ficar no acervo se
       ninguém for buscá-la. Cumpre os itens 4 e 9 do passo a passo interno.
       O score pondera a similaridade média dos melhores trechos pela COBERTURA: um job que
       casa em objetivo, escopo e equipe é parecido de verdade; um que casa num parágrafo é
       coincidência e não deve ser sugerido.
     - **Sob demanda**: ferramenta `SearchHistoricalArchiveTool` registrada em
       `RespondToMessageJob`, com o parâmetro `fonte` escolhendo entre o que a Papyrus escreveu
       e o que veio do cliente. Não é injeção automática de contexto: despejar propostas
       inteiras em toda conversa gastaria contexto com material que talvez não seja usado.
   - **Citação é obrigatória**: cada trecho devolvido pela ferramenta traz o campo `referencia`
     já montado ("acervo Papyrus: projeto 25001 — Petrobras (4. ESCOPO, 2025)"), e as instruções
     exigem citar sempre que o acervo for usado. Informação do acervo apresentada sem fonte é
     indistinguível de invenção, e o consultor precisa poder conferir.
   - Conferência antes de indexar: `bin/rails runner script/rag/report.rb --path PASTA --ocr`
     gera um HTML navegável com todos os trechos, sem tocar no banco nem gerar embedding.
   - **Propostas aprovadas dentro do sistema** — continua adiado: só entrega valor depois que
     existir volume real de propostas aprovadas *pelo próprio sistema* pra indexar; hoje é
     zero. Quando chegar a hora, reaproveita a mesma infraestrutura.

4. ~~**Memória por cliente**~~ — **implementado** (`KnowledgeNote`), com a curadoria como
   parte do desenho, não como refinamento futuro:
   - A IA PROPÕE via `RememberForFutureProposalsTool` (categorias fechadas: preferência do
     cliente, decisão de escopo, condicionante de órgão, correção do consultor). A nota nasce
     `pending` e **não é recuperável**; quem promove a conhecimento é o consultor, clicando no
     card do chat (`KnowledgeNotesController#approve`).
   - **Por que a curadoria não é opcional:** o acervo vale porque tudo nele foi escrito e
     assinado por gente. Deixar a IA gravar direto o que "achou interessante" faria a
     inferência dela voltar meses depois citada como "memória da Papyrus" — indistinguível de
     um fato verificado. É o mesmo princípio da seção 1 aplicado a conhecimento em vez de preço.
   - Aprovar e embedar são atômicos: nota aprovada sem vetor é inencontrável, o que na prática
     equivale a não ter sido aprovada. Se o embedding falhar, ela continua pendente.
   - Uso: `GenerateSummaryJob` traz as notas aprovadas do cliente no resumo de toda proposta
     nova dele; a citação (`KnowledgeNote#reference`) diz "memória da Papyrus", nunca "acervo".
   - **Proposta gerada pelo sistema** entra no acervo em `IndexApprovedProposalJob`, disparado
     por `proposals#approve` — só depois de aprovada, quando já passou por revisão humana.
     Fica com `origin: "sistema"` (o acervo em disco é `origin: "acervo"`), e a ferramenta de
     busca cita "proposta gerada no sistema" em vez de "acervo Papyrus". Indexar rascunho faria
     o RAG ensinar a IA a repetir o que o consultor descartou.

**Decisão de design:** não adotar a arquitetura genérica de "tipos de conhecimento" proposta no estudo — o domínio deste projeto é estreito e já bem modelado (`study_types`, `professionals`, `study_templates`, parâmetros de logística direto em `project_pricings`). Preferir estender essas tabelas concretas conforme a necessidade aparecer, em vez de construir uma camada de abstração genérica antecipadamente.

---

## 12. Convenções do projeto

- Stack gerado com `rails new papyrus_propostas -d postgresql --css=tailwind` (Rails 8.1, Hotwire/Turbo/Stimulus por padrão).
- Autenticação: usar o gerador nativo (`bin/rails generate authentication`), não Devise.
- Jobs/WebSocket: usar Solid Queue + Solid Cable (já no Gemfile), não introduzir Redis/Sidekiq salvo necessidade concreta.
- PostGIS: adicionar `activerecord-postgis-adapter`, habilitar extensão `postgis` via migration, ajustar `config/database.yml` para adapter `postgis`.
- Preço é sempre calculado em Ruby, nunca pela IA — a IA só alimenta parâmetros de escopo (tipo de estudo, distância, sobreposições) que entram no motor de cálculo.
- Layout do documento final vem do modelo `.docx` real da Papyrus (preenchido via `rubyzip`), não é gerado pela IA nem recriado em HTML/CSS — ver seção 8.
- IA: usar a gem `ruby_llm` (não chamar a API da Anthropic diretamente). Instalada via `rails generate ruby_llm:install chat:Conversation message:Message` — por isso `Conversation` usa `acts_as_chat` e `Message` usa `acts_as_message` (gem renomeia associações automaticamente, ex.: `acts_as_message chat: :conversation`). `ToolCall` e `Model` mantêm os nomes padrão da gem. Configuração em `config/initializers/ruby_llm.rb` (`anthropic_api_key`, `default_model`); rodar `bin/rails ruby_llm:load_models` para popular a tabela `models` assim que a chave real da Anthropic estiver configurada.
- Views HTML+ERB são validadas pela gem `herb` (`bin/herb lint`, configurada em `.herb.yml`, rodando também no `bin/ci` e no workflow do GitHub Actions). O linter em si é o pacote npm `@herb-tools/linter`, fixado no `package.json` na mesma versão da gem — ao atualizar uma, atualizar a outra e o campo `version:` do `.herb.yml`.
- Anexos de conversa (TR, KMZ, complementares) são Active Storage nativo (`has_many_attached :attachments` em `Message`), não uma tabela `attachments` própria.
- RAG do acervo (seção 11.1): rodar `script/rag/report.rb` e revisar o HTML ANTES de
  `script/rag/index.rb` — indexar é a única etapa que custa dinheiro. A ingestão é idempotente
  por SHA256 + `Rag::Indexer::PIPELINE_VERSION`; suba a versão ao mudar extração ou chunking de
  forma que altere os trechos, senão o que já está indexado não é refeito.
- Stay22 (hospedagem, ver seção 5): chave de API pendente — configurar em `.env`/`ANTHROPIC`-style (`STAY22_API_KEY`) ou `Rails.application.credentials`, nunca hardcoded. Enquanto a chave não estiver configurada, a integração fica com o job/estrutura prontos mas sem chamada real, mesmo padrão usado para Anthropic/Mapbox.
