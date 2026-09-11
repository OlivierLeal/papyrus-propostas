# Papyrus Propostas

Sistema para automatizar a geração de **Propostas Técnicas e Comerciais** da Papyrus Consultoria Ambiental. O consultor sobe um ET (Pedido Técnico do Estudo), opcionalmente um TR (Termo de Referência), um arquivo KMZ e documentos complementares; o sistema processa tudo (IA + geoespacial), o consultor revisa e ajusta via chat, aprova o preço e recebe um PDF pronto no padrão visual da Papyrus.

**Nota de terminologia (correção feita em 2026-08, o cliente havia explicado errado antes):** **ET** = Pedido Técnico do Estudo — o documento em que o CLIENTE explica o que está pedindo à Papyrus. É o documento principal/obrigatório, a base do escopo. **TR** = Termo de Referência — documento que vem de uma INSTITUIÇÃO/órgão ambiental, com exigências de metodologia, diagnósticos e condicionantes; funciona como GUIA de como executar o ET, nunca no lugar dele. O TR é opcional — nem todo cliente tem ou envia um.

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
2. Clica em "Nova Proposta" → **Tela de Setup**: informa nome do cliente e tipo de estudo, sobe o ET (PDF/DOCX, principal), opcionalmente o TR (PDF/DOCX, guia institucional), sobe o KMZ, adiciona documentos complementares (opcional).
3. Revisa os arquivos na tela de setup e confirma ("Gerar Proposta").
4. **Processamento em background** (paralelo, via jobs):
   - IA analisa o ET (e o TR, quando enviado).
   - Módulo geoespacial processa o KMZ.
   - IA lê os documentos complementares.
5. Sistema apresenta um **resumo estruturado** na Tela de Resultado (via WebSocket/Action Cable, com progresso em tempo real).
6. Consultor revisa o resumo; pode corrigir via chat (loop: ajustar → revisar até aprovar).
7. Abre a **Tela de Precificação**: sistema carrega o template de horas do tipo de estudo, consultor ajusta horas se necessário, sistema recalcula o preço automaticamente em tempo real.
8. Preço aprovado → solicita geração do PDF.
9. IA escreve o texto das seções; o backend monta o PDF no layout padrão Papyrus.
10. PDF pronto para download; proposta salva no histórico (arquivos + PDF + conversa completos).

Documentos complementares podem ser enviados a qualquer momento da conversa, não só no início —
e desde 2026-09 o **KMZ/KML também** (ver "KMZ enviado pelo chat" logo abaixo).

**KMZ enviado pelo chat, não só na Tela de Setup (2026-09, pedido do consultor: proposta criada
sem KMZ, quer jogar o arquivo no chat depois e ter o mapa/análise geoespacial do mesmo jeito).**
Antes, `ProcessKmzJob` só era enfileirado uma vez, por `ConversationsController#create` — uma
proposta que nasceu sem KMZ ficava sem mapa/achados geoespaciais pra sempre, a não ser recriando a
conversa inteira. `MessagesController#create` agora detecta `.kmz`/`.kml` por extensão entre os
anexos soltos do composer do chat (mesmo critério de `ConversationsController#kmz_filename?`,
extraído pra `ApplicationController` pra servir os dois), marca `kind: "kmz"` em vez de
`"complementary"` e enfileira `ProcessKmzJob` na hora — o job em si não muda nada (mesma extração
de geometria, cruzamento com `ibge_municipalities`, mapa/croqui, achados de área/perímetro/
município), só passou a poder ser disparado a qualquer momento, não só no setup.
- `Conversation#attachment_of_kind` trocou de `.first` pra `.last` — com o KMZ podendo chegar a
  qualquer momento, um consultor pode mandar um substituto/corrigido depois do primeiro, e o mais
  RECENTE é o que vale (mesmo princípio de `Message#stale_for_llm?` pros documentos que vão pra
  IA). `ProcessKmzJob` ganhou `conversation.geospatial_result&.destroy!` antes de criar o novo —
  `geospatial_result` é 1-1 (índice único em `conversation_id`), sem isso um KMZ substituto
  derrubava o job com `RecordNotUnique` (capturado pelo `rescue` como "failed", silencioso).
- `RespondToMessageJob` roda em paralelo com `ProcessKmzJob` (que processa em background e pode
  levar alguns segundos — extração de geometria, PostGIS, chamada à Mapbox) — a resposta da IA
  deste turno pode não ter ainda o mapa/achados prontos; eles ficam disponíveis pro turno seguinte,
  mesmo padrão de "peça de novo em instantes" já usado pro cronograma (seção 8). O card do mapa na
  Tela de Resultado (`conversations/show.html.erb`) só depende de `geospatial_result.present?`, não
  de `processing_steps` — aparece sozinho assim que o job termina (`mark_step!` já dispara
  `broadcast_refresh`).

**Escolher arquivos em mais de uma rodada no mesmo campo (2026-09, achado ao vivo, relato do
consultor).** Todo campo `<input type="file" multiple>` do sistema (ET/TR/KMZ/complementares na
Tela de Setup, e o clipe dos dois composers de chat) usa o mesmo
`app/javascript/controllers/file_list_controller.js` pra mostrar a seleção como chips removíveis.
Reabrir "Escolher arquivos" pra pegar MAIS arquivos de OUTRA pasta troca `input.files` pela
seleção nova sozinho — comportamento nativo do navegador, não um bug do Rails — e sem compensar
isso no JS, a segunda rodada de escolha apagava a primeira (só sobravam os arquivos da pasta mais
recente). Corrigido: o controller passou a manter `this.files` como estado de verdade que
sobrevive entre trocas de seleção (inicializado em `connect()`, começa vazio) — a cada "change"
do input, faz a UNIÃO de `this.files` com o que está em `input.files` naquele momento (dedup por
nome+tamanho+data de modificação, já que `File` não tem identidade estável entre seleções — re-
escolher o mesmo arquivo funde em vez de duplicar) e reconstrói `input.files` a partir da união
(`DataTransfer`, único jeito de "editar" a seleção de um `<input type="file">` — mesmo truque que
`#remove` já usava, e que `file_drop_controller.js`, seção de arrastar-e-soltar do composer, já
usava pra mesclar o solto). Como o `file_drop_controller` já entrega `input.files` pré-mesclado
antes de disparar "change", a união funciona igual nos dois casos, sem duplicar.
Verificado com teste de sistema de verdade (`test/system/file_list_accumulation_test.rb`,
Selenium/Chrome headless): escolher um arquivo, depois escolher outro no mesmo campo, os dois
chips aparecem juntos; remover um mantém o outro.

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
| Hospedagem | Stay22 API (`api.stay22.com/v2/accommodations`) — busca opções de acomodação pelo município identificado no ET/TR; consultor escolhe a melhor opção no chat (ver seção 5) |
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
- `messages` — `acts_as_message`; colunas nativas da gem: conversation_id, role, content, content_raw, tokens de entrada/saída/cache. Anexos (ET, TR, KMZ, complementares) via Active Storage nativo (`has_many_attached :attachments`), **não** uma tabela `attachments` própria — o upload na Tela de Setup é a primeira mensagem do usuário na conversa, já com os arquivos anexados. `user_id` (opcional — ver "Quem mandou cada mensagem" abaixo)
- `tool_calls` / `models` — tabelas nativas da gem (function-calling e registro de modelos LLM com pricing/capabilities); não fazem parte do domínio, mas ficam disponíveis para uso futuro (ex.: extração estruturada de dados do ET)

**Quem mandou cada mensagem, pro chat mostrar o nome de cada um (2026-09).** `Conversation`
(diferente de `GeneralChat`) não é escopado por usuário — `Conversation.find`/`MessagesController
#set_conversation` não filtram por `current_user`, de propósito: mais de um consultor pode
acompanhar/participar da mesma proposta, e o broadcast de uma mensagem nova (`broadcast_render_to`,
ver seção 6) chega em toda aba aberta dela, não só em quem mandou. Sem saber QUEM escreveu, o chat
rotulava toda mensagem `role: "user"` como "Você" pra qualquer um que estivesse olhando — errado
pro consultor B ler a mensagem do consultor A.
- `messages.user_id`/`general_messages.user_id` (`belongs_to :user, optional: true`) —
  `Message#assign_current_user`/`GeneralMessage#assign_current_user` (`before_create`, só quando
  `role == "user"` e `user_id` ainda não veio setado) grava `Current.user` sozinho, sem precisar
  tocar em `MessagesController`/`ConversationsController#create` (a mensagem de setup) nem em
  nenhum outro ponto que já cria mensagem "user". **`before_create`, não `before_save`** (diferente
  de `hide_tool_result!` — ver comentário no model): mensagem "user" sempre nasce com o role já
  definido (`ChatMethods#add_message` → `create!` direto), nunca o placeholder
  assistant-depois-atualizado que só existe pra streaming da resposta da IA.
- Fica `nil` de propósito pras mensagens "user" INTERNAS do `ask_internally` (o snapshot
  `[ESTADO ATUAL DA PROPOSTA]`, instruções da checklist) — rodam em background job, sem
  `Current.user` (fora do ciclo de uma request), e nenhum humano "digitou" aquilo mesmo. Também
  fica `nil` em mensagens de antes desta coluna existir.
- **`conversations/_message.html.erb` mostra `message.user&.name || "Você"`, DELIBERADAMENTE sem
  comparar com `current_user`.** `broadcast_render_to` roda num job à parte
  (`Turbo::Streams::ActionBroadcastJob`) — a mesma HTML renderizada ali é transmitida pra TODO
  mundo que está com a proposta aberta, então comparar com `current_user` acertaria só pra quem
  originou o request (ou nem isso — `Current` é resetado entre jobs) e erraria pro resto. Mostrar
  sempre o nome de verdade evita depender de em qual contexto (request normal vs. broadcast
  assíncrono) a mensagem está sendo renderizada.
- `general_chats/_message.html.erb` **não muda** — `GeneralChat` é sempre escopado por
  `current_user.general_chats` (`GeneralChatsController`/`GeneralMessagesController`), nunca
  compartilhado entre consultores, então "Você"/"IA" já era (e continua sendo) sempre correto ali;
  o `user_id` em `general_messages` é gravado só por consistência com `Message`, sem uso na view.
- Verificado com teste de controller (resposta HTML de verdade, não só o model): consultor B abre
  a proposta do consultor A, a mensagem de A aparece com "Consultora Um" (nome de A), e a de B
  aparece como "Você".

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

1. **Composição da equipe**: ao avançar da revisão para a precificação (`Proposal#build_with_ai_suggested_team!`), a IA sugere horas por profissional/entregável com base em tudo que já foi extraído do ET, do TR (quando houver) e dos documentos complementares nesta conversa (ver `conversation.ask_internally`). Dois caminhos, conforme o tipo de estudo ter ou não `study_templates` cadastrados:
   - **Com `study_templates` (hoje só `eia_rima`):** a sugestão é **restrita ao "menu"** de profissionais × entregáveis já cadastrados para o tipo de estudo — a IA nunca inventa um `professional_id` ou `deliverable_name` novo; qualquer linha que não bata exatamente (por id + nome normalizado) com uma linha do menu é descartada e vira achado `sugestao`. Falha/nenhuma linha válida cai no fallback determinístico `Proposal#build_from_template!`, que copia as horas padrão (`hours_office_default`/`hours_field_default`) direto do template.
   - **Sem `study_templates` (2026-09, pedido da Papyrus):** o "menu" passa a ser `Professional.active` inteiro (menos os `always_included`), com cargo + especialidades, e a IA escolhe QUEM entra e o QUE cada um entrega nesta proposta (`roster_suggestion_prompt`/`apply_roster_lines!`). Continua sem inventar gente (`professional_id` tem que ser de profissional real e ativo — id inválido vira achado `sugestao`), mas o `deliverable_name` é livre (não há catálogo de entregável por tipo de estudo fora do `eia_rima`). Falha/JSON inválido cai no mesmo `rescue` → `build_from_template!` (só Diretoria/Coordenação).
   - Em ambos os casos os `always_included` (Diretoria/Coordenação) entram sozinhos via `ensure_always_included_lines!`, e o consultor ajusta tudo na Tela de Precificação.
2. **Ajuste manual**: grade editável na Tela de Precificação (`proposals#show`/`#update`) — Profissional × Entregável × Horas escritório/campo, mais adição/remoção de linhas fora do menu sugerido (`proposal_professionals#create`/`#destroy`). Recalcula ao submeter o formulário.
3. **Cálculo** (`ProjectPricing#recalculate!` / `ProposalProfessional#recalculate_subtotal`):
   - `C1` = horas escritório × taxa escritório
   - `C2` = horas campo × taxa campo
   - `C3` = subtotal profissional = (C1 + C2) × BDI × impostos
   - `C4` = logística = (aluguel/dia + alimentação/dia) × dias de campo + combustível total
   - `C5` = custos externos (ARTs, terceiros: fauna, flora, drone) — lançados manualmente por proposta em `external_costs` (jsonb)
   - `C6` = TOTAL = Σ profissionais + logística + externos
4. Parâmetros do sistema: tabela de profissionais com taxa/dia por escritório e campo (`professionals`); BDI e impostos (`tax_multiplier`) editáveis por proposta em `project_pricings` (defaults 1.20/1.25). **Não existe mais uma tabela de configuração de logística** (`logistics_configs` foi removida) — aluguel/dia, alimentação/dia, combustível total e dias de campo são campos digitados direto na Tela de Precificação por proposta.
5. **Hospedagem**: não entra no cálculo automático. O sistema consulta a API do Stay22 usando o município identificado no ET/TR e apresenta as opções de acomodação como mensagem no chat; o consultor escolhe a melhor opção manualmente. Por enquanto isso fica só registrado na conversa (informativo) — pendente da chave de API do Stay22.
6. Saídas: tabela de preço auditável por linha, cronograma de desembolso por parcelas (`payment_schedule_amounts`, default 30/60/5/5), dados prontos para o PDF. Proposta só é editável enquanto `status != "approved"`; aprovar (`proposals#approve`) trava os campos e conclui a conversa.

---

## 6. Pipeline de processamento de dados

Após confirmação na tela de setup, arquivos vão para Active Storage (criptografado) e disparam jobs — a maioria em paralelo, exceto uma cadeia sequencial:

- **ProcessET**: extração de texto (ou envio nativo do PDF/DOCX pra Claude) do documento PRINCIPAL/obrigatório (o pedido do cliente) → IA identifica tipo de licença, tipo de estudo, órgão ambiental, municípios, diagnósticos, condicionantes, ressalvas. Ao concluir, dispara a busca de hospedagem (Stay22) usando o município identificado.
- **ProcessLegalNorms** (2026-09): roda **depois do ET e antes do TR**, nunca em paralelo com nenhum dos dois — só depois que o ET identifica o(s) município(s) é que dá pra saber o âmbito certo (municipal/estadual/federal) pra pesquisar no CAL (ver seção 11.2). Sem município identificado, pula direto pro TR. Quando roda, os achados que traz (`source_kind: "cal"`) já estão disponíveis ANTES do TR ser lido, pra a IA cruzar o que a legislação exige com o que o TR institucional pede.
- **ProcessTR**: mesma extração do ET, sobre o TR institucional OPCIONAL (guia de execução, quando o cliente enviar um) — reforça/complementa o que o ET (e o CAL, quando pesquisado) já trouxeram, sem bloquear o processamento se não existir.
- **ProcessKMZ**: descomprime → parseia XML/KML (Nokogiri) → extrai coordenadas → RGeo calcula área (ha), perímetro (km), centroide → PostGIS cruza com as 6 camadas de referência → gera imagem do mapa (Mapbox Static API, bounding box + margem 20%).
- **ProcessCompDocs**: IA identifica tipo de cada documento complementar e extrai escopos anteriores, preços de referência, condicionantes, metodologias, equipes usadas.

ProcessKMZ e ProcessCompDocs continuam em paralelo com a cadeia ET→CAL→TR, sem depender dela. Um job final (**GenerateSummary**) só dispara quando tudo termina, e monta o resumo estruturado exibido na Tela de Resultado via WebSocket.

**Ponto de atenção:** ETs/TRs grandes (100+ páginas) com muitos complementares podem levar 60–120s para processar — feedback visual (barra de progresso por etapa) é essencial. A cadeia ET→CAL→TR ser sequencial (em vez de tudo em paralelo, como antes) alonga esse tempo quando o CAL está configurado e há município identificado — trade-off aceito, é o preço de pesquisar o âmbito certo antes de ler o TR.

---

## 7. Documentos complementares — o que a IA deve extrair

Tipos aceitos: propostas anteriores semelhantes, resoluções/normas específicas, projetos básicos do empreendimento, relatórios ambientais anteriores, condicionantes de licenças anteriores, atas de reunião com órgão licenciador, mapas/plantas, estudos técnicos prévios, comunicados/ofícios INEMA/IBAMA.

Regras:
- Proposta anterior como referência → reutilizar estrutura de escopo, padrão de preço, equipe utilizada, ressalvas aplicadas, metodologias descritas.
- Resoluções/normas → incorporar nas referências legais e ajustar escopo conforme exigências.
- Condicionantes de licenças anteriores → identificar e sinalizar impacto em escopo/preço.
- Projeto básico → extrair tipo de empreendimento, capacidade/potência, infraestrutura prevista.
- Sempre informar ao usuário quais informações foram extraídas de cada documento, para validação.
- Se um complementar conflitar com o ET ou o TR, sinalizar a divergência e pedir orientação ao usuário (nunca decidir sozinho).

---

## 8. Geração do documento (DOCX — decisão revista, era PDF)

**Mudança de escopo:** o desenho original (seção histórica) previa PDF via Grover/Chrome headless.
A Papyrus decidiu que o formato final precisa ser **DOCX**, preenchendo um modelo `.docx` real
deles (com a identidade visual já aplicada) em vez de recriar o layout em HTML/CSS.

Processo em duas etapas, com responsabilidades separadas (princípio mantido):

1. A IA produz um **texto estruturado** com todo o conteúdo (seções, dados, escopo, equipe, valores), guiada pelo "Prompt de Geração de Proposta" (seção 9), incluindo se o ET ou o TR exige apresentação em documentos/envelopes separados (técnico × comercial).
2. O backend Rails preenche o(s) modelo(s) `.docx` da Papyrus com esse conteúdo — abrindo o arquivo (é um zip com XML dentro), substituindo marcadores de texto no `word/document.xml` via `rubyzip`, e re-empacotando. **Não é a IA que mexe no arquivo** — ela só gera o texto que entra nos marcadores.

O layout visual (fontes, cores, margens, logotipos, tabelas) vem pronto do modelo `.docx` da Papyrus — o código só substitui conteúdo, nunca redesenha layout. Isso garante consistência visual entre propostas independente do conteúdo gerado.

**Nome do arquivo:** por padrão o sistema monta `número / cliente / ato de licenciamento / nome do
projeto / _Rev.NN` (`Proposal#docx_filename`/`#standard_filename_base` — padrão pedido pelo
consultor, 2026-09; município/UF SAÍRAM do nome de propósito, não fazem mais parte do padrão).
"Ato" (LP, LI, RLP, LO, ASV, AMF etc.) e "nome do projeto" vêm dos achados `tipo_licenca`/
`empreendimento` já extraídos do ET/TR (`ProjectFinding`) — não são parâmetro novo, só passaram a
alimentar o nome do arquivo também:
- `ato_licenciamento` extrai as siglas já escritas no(s) achado(s) (`\b[A-Z]{2,4}\b`); sem
  nenhuma sigla no texto, tenta casar contra os nomes completos mais comuns (mapa fixo em
  `Proposal::LICENSE_ACT_NAMES` — cobre os atos mais comuns, não é exaustivo). Combina siglas de
  TODOS os achados `tipo_licenca` ativos desta conversa (podem vir em registros separados, um ato
  por achado) com `+`, sem repetir — mesma convenção `"LP+LI"` já usada de verdade pela Papyrus.
  Achado ao vivo (conversa 35/proposta 21): a IA às vezes escreve o ato por extenso ("Licença
  Prévia e Licença de Instalação") em vez da sigla — sem a normalização, o nome do arquivo saía
  enorme.
- `nome_projeto` pega o achado `empreendimento` mais curto entre os ativos (não o de fonte mais
  autoritativa — `ProjectFinding::SOURCE_KINDS` decide o FATO certo, aqui o objetivo é achar o
  texto mais limpo pra nome de arquivo; a versão curta às vezes vem de um complementar, a frase
  técnica inteira do ET). Quando só existe a frase longa (comum, sem versão curta disponível), o
  segmento é OMITIDO em vez de truncado no meio de uma palavra — nome incompleto mas limpo é
  melhor que completo e cortado feio.
- Se o consultor DITAR o nome no chat ("o arquivo tem que se chamar PTC26002_PMM_LU_Simões Filho")
  — o que acontece quando a pasta na rede e o controle de propostas já foram criados com aquele
  nome (itens 1 e 2 do passo a passo interno) — a IA passa `nome_arquivo` para a ferramenta e o
  nome fica gravado em `proposals.docx_filename_override`, valendo também para as versões
  seguintes, e nada do que foi descrito acima entra em jogo. O sistema só acrescenta `_Rev.NN`
  (se ele já não tiver escrito uma) e troca o prefixo PTC/PT/PC quando a proposta sai em dois
  arquivos. "padrão" no chat devolve a nomeação ao sistema.

**Capa sem o prefixo PT/PTC/PC (2026-09, pedido do consultor).** A capa do `.docx` (texto
`{{NUMERO_PROPOSTA}}/20` + "26" + " - Rev. {{REVISAO_ATUAL}}`", fixo no modelo) mostrava o número
completo com prefixo — "PTC26018/2026 - Rev. 00". Passou a mostrar só os dígitos — "26018/2026 -
Rev. 00" — sem letra nenhuma. `Proposal#docx_numero_capa(kind)` reusa `#docx_numero_proposta`
(que continua com o prefixo, sem NENHUMA mudança) e só tira as letras do começo
(`.sub(/\A[A-Z]+/, "")`); `GenerateProposalDocumentTool` passou a mandar `docx_numero_capa` no
lugar de `docx_numero_proposta` só pro placeholder `NUMERO_PROPOSTA` (o único uso dele no
modelo — confirmado que `{{NUMERO_PROPOSTA}}` só aparece na capa, nada mais depende disso).
`docx_numero_proposta` (com prefixo) continua sendo a fonte de verdade em todo resto do sistema
— nome de arquivo (`standard_filename_base`), busca de conversa por número
(`Conversation#matches_search?`) e indexação no RAG (`LearnFromRevisedProposalTool`/
`IndexApprovedProposalJob`) — nada disso mudou, é só a capa que parou de mostrar a letra.
Efeito colateral aceito: como técnica/comercial/combinado têm a MESMA sequência de dígitos (só o
prefixo mudava entre eles), a capa por si só não distingue mais qual variante é — quem faz isso
agora é só o título (`TITULO_LINHA2`/`TITULO_LINHA3`, "TÉCNICA"/"COMERCIAL"/"TÉCNICA E COMERCIAL"),
que já existia do lado da capa pra isso.

**Revisão do modelo (2026-08, a partir do PTC26002_PMM_Rev01 trazido pela Papyrus):** a seção 10
deixou de ter o quadro de preço aberto por profissional/entregável — o valor que o cliente lê é o
total, escrito na frase de abertura (`{{PRECO_TOTAL}}`), e o único quadro é o de desembolso, agora
com **N° | MARCO | R$ | DATA**. A data de cada parcela é digitada pelo consultor na Tela de
Precificação e mora dentro do próprio `payment_schedule` (jsonb), junto do marco e do percentual;
parcela sem data sai em branco no documento. Também nesta revisão: o quadro de produtos perdeu a
coluna QUANT., a seção 9 (prazo) ganhou um segundo parágrafo, e as obrigações da CONTRATANTE
perderam os itens de rádio comunicador e espaço físico/CATFA. O cálculo continua auditável linha a
linha na Tela de Precificação — o que mudou é o que vai impresso para o cliente.

**O quadro de Preço voltou, e o de Desembolso passou de R$/DATA pra % (2026-09, pedido do
consultor, a partir de uma proposta real trazida como referência).** A seção "PREÇO E CONDIÇÕES
DE PAGAMENTO" ganhou de volta um quadro ANTES do Desembolso — não é o quadro por profissional/
entregável que saiu em 2026-08 (aquele nunca voltou), é um quadro de **1 linha só** com o preço
TOTAL: **N° | SERVIÇO | PREÇO R$**. O texto de abertura deixou de citar `{{PRECO_TOTAL}}` inline
("O preço proposto... é de R$ X") e passou a apontar pro quadro ("...está no Quadro N-1"), igual
já fazia pro Desembolso — `{{PRECO_TOTAL}}`/`Proposal#docx_total_price` continuam mapeados
(inofensivo, mesmo padrão de placeholder que saiu do texto mas segue passado — ver "Ref.:" acima)
mas não aparecem mais no modelo. O Desembolso (agora o 2º quadro da seção) perdeu as colunas
**R$**/**DATA**, viraram uma só, **% DO ITEM** — o percentual já morava em `payment_schedule`
(jsonb), então é exibição mais simples, não motor de cálculo novo; a data de cada parcela
continua existindo e editável na Tela de Precificação, só não vai mais impressa no `.docx`.
- **`Proposal#docx_price_rows`** — sempre 1 linha (`[[docx_servico_label, preço formatado]]`,
  auto_number: true na 1ª coluna). **`Proposal#docx_servico_label`** deriva o nome do serviço
  do(s) ato(s) de licenciamento já identificados (`license_act_acronyms`, mesma sigla do nome do
  arquivo) — nunca da IA: "RLP" → "Renovação da Licença Prévia - RLP", vários atos combinam com
  "e" no nome e "+" na sigla ("Licença Prévia e Licença de Instalação - LP+LI"). Sem ato
  identificado (sigla fora do catálogo `LICENSE_ACT_NAMES`, ou nenhum achado `tipo_licenca`), cai
  pro texto livre que a IA já escreve em `descricao_servico` (mesmo parâmetro usado na linha
  "Ref.:") — nunca puro `nil`/vazio no documento, o último fallback é o genérico "Serviço".
- **`Proposal#docx_payment_schedule_rows`** trocou de `[label, R$, data]` pra `[label, %]`, lendo
  `payment_schedule` direto (não mais `payment_schedule_amounts`, que continua existindo e sendo
  usado na VIEW da Tela de Precificação — só o `.docx` parou de mostrar R$/data por parcela).
- **Índices das tabelas remapeados** (`GenerateProposalDocumentTool#build_tables`,
  `ProposalDocxFiller`): 0=revisões, 1=produtos, 2=equipe, **3=preço (NOVO)**, 4=desembolso (era
  3). Mesma disciplina de sempre ao adicionar tabela no modelo — todo índice depois do ponto de
  inserção sobe 1.
- **Edição do modelo**: como sempre, string crua no `word/document.xml`, nunca `Nokogiri#to_xml`.
  A tabela de Preço nasceu de uma CÓPIA da tabela de Desembolso (mesmos `tblPr`/bordas/estilo,
  só 3 colunas em vez de 4 — a largura das colunas `R$`+`DATA` removidas foi somada numa só
  `% DO ITEM`/`PREÇO R$`, redistribuindo a largura total da tabela em vez de encolher), cortada
  pra 1 linha de dado só (a de Desembolso manteve as 9). Verificado ao vivo (LibreOffice headless
  → PDF → captura): os dois quadros saem exatamente como a referência trazida pelo consultor,
  numerados "12-1"/"12-2" nesta rodada (a numeração real desta seção no modelo, calculada
  automaticamente — não é fixa "11-1"/"11-2" como na referência, que veio de uma proposta sem o
  capítulo "ITENS NÃO PREVISTOS" que empurra a numeração em 1 nesta versão do modelo; virou
  "13-1"/"13-2" pouco depois, com o capítulo fixo "EXIGÊNCIAS SMS" logo abaixo).

**"EXIGÊNCIAS SMS" virou capítulo fixo, logo depois de EQUIPE TÉCNICA (2026-09, pedido do
consultor a partir de um texto pronto da Papyrus).** Texto INTEIRO fixo do modelo — nada vem da
IA nem de `ProjectFinding` nenhum, mesmo princípio das "Observações fixas no item de preços"
(seção 8, mais abaixo) e da frase de proposta complementar de "ITENS NÃO PREVISTOS": um parágrafo
introdutório mais dois grupos com rótulo em negrito ("Documentos da Empresa:"/"Documentação dos
Colaboradores:") e listas reais com marcador "●" (`w:numPr`, `numId=2` — reaproveita a MESMA
definição de lista das OBRIGAÇÕES DA PAPYRUS; bullet não tem contador pra "colidir" entre listas
diferentes, então reusar o numId é seguro e não precisou mexer em `word/numbering.xml`). Vira a
**10ª seção de nível 1** do modelo (entre EQUIPE TÉCNICA, que continua 9ª, e PRAZO DE EXECUÇÃO,
que passa de 10ª pra 11ª — e por isso PRAZO/VALIDADE/PREÇO/DADOS BANCÁRIOS sobem 1 cada, mesmo
efeito dominó de sempre ao inserir capítulo novo, ver "ITENS NÃO PREVISTOS" acima).
- `ProposalDocxFiller::SECAO_PRAZO_NUMERO` foi de 10 pra 11 — é ele quem numera os Quadros do
  cronograma (`Quadro 11-1`/`Quadro 11-2`, dinâmicos, gerados na hora — não são texto fixo do
  modelo, então não precisam de edição de XML nenhuma pra renumerar, só o constante Ruby).
  `SCHEDULE_CAPTION_PREFIXES` ganhou `"Quadro 10-"` na lista de prefixos históricos (ao lado do
  já existente `"Quadro 9-"`) — pra `insert_schedule_section` continuar reconhecendo e
  substituindo (sem duplicar) o bloco de cronograma de um `.docx` que foi gerado ANTES desta
  mudança, quando PRAZO ainda era a 10ª seção.
- Os literais `Quadro 12-1`/`Quadro 12-2` (Preço/Desembolso, ver acima — só existiam desde a
  rodada anterior desta mesma sessão) viraram `Quadro 13-1`/`Quadro 13-2` — string crua no
  `word/document.xml`, igual sempre, nunca `Nokogiri#to_xml`.
- Verificado ao vivo (LibreOffice headless → PDF → captura, proposta real): "9. EQUIPE TÉCNICA" →
  "10. EXIGÊNCIAS SMS" (texto + as duas listas com bullet) → "11. PRAZO DE EXECUÇÃO" → "12.
  VALIDADE" → "13. PREÇO E CONDIÇÕES DE PAGAMENTO" (com `Quadro 13-1`/`13-2` certos) → "14. DADOS
  BANCÁRIOS" — a cadeia inteira renumerada sozinha, exceto os 3 literais que precisaram de edição
  manual (2 captions + a chamada `SECAO_PRAZO_NUMERO`).

**Validade da proposta sempre 90 dias, inclusive na técnica-sozinha (2026-08):** a seção
"VALIDADE DA PROPOSTA" (texto fixo "Esta proposta tem validade de 90 dias.", sem placeholder —
nunca varia por proposta) foi movida pra ANTES de "PREÇO E CONDIÇÕES DE PAGAMENTO" — antes ficava
depois de "DADOS BANCÁRIOS", ou seja, só existia no lado comercial/combinado, e sumia quando só a
proposta técnica saía (`proposal.status == "draft"`, ver `GenerateProposalDocumentTool#execute`).
A numeração das seções é automática (mesmo `numId`/`pStyle="Ttulo1"` de todo título de nível 1),
então mover o parágrafo bastou pra reindexar sozinha — mas o texto "Quadro 10-1: Desembolso" (na
seção de Preço) é literal, não é campo de referência automática do Word, e teve que ser atualizado
à mão pra "Quadro 11-1" quando a seção de Preço passou a ser a 11ª (era a 10ª). Efeito colateral
aceito: a validade deixou de aparecer no documento COMERCIAL quando gerado separado (technical ×
commercial, `document_split == "separated"`) — ela existe no técnico e no combinado, não mais
sozinha do lado comercial.

**Assinatura também no fim da proposta TÉCNICA (2026-09):** o bloco de assinatura em negrito
(Papyrus + CNPJ, cliente + CNPJ, com `{{NOME_CLIENTE_ASSINATURA}}`/`{{CNPJ_CLIENTE}}`) só existia
uma vez no modelo, no fim do corpo — ou seja, só saía no arquivo COMERCIAL (ou no combinado); a
proposta TÉCNICA (draft, ou separada) terminava sem assinatura nenhuma. O modelo ganhou uma
SEGUNDA cópia do mesmo bloco, logo depois de "Data do aceite da proposta:" (fim da seção
VALIDADE, ainda do lado técnico) — mesma técnica de sempre, string crua copiada do bloco
original, `w14:paraId` trocado só por higiene.

Como os dois blocos usam os MESMOS placeholders, `fill_simple_placeholders!` preenche as duas
cópias sem precisar de nada novo — mas isso criava um problema no documento ÚNICO (`fill`, sem
split): sem nenhum corte, as DUAS cópias sobrevivem juntas no mesmo arquivo, e o cliente via a
assinatura duas vezes (achado ao vivo gerando o combinado). `ProposalDocxFiller#build` agora
distingue: quando SEM split (`fill`, `block_given?` falso), roda
`remove_technical_signature_duplicate!` — apaga só a cópia nova (entre "Data do aceite" e
`FIRST_COMMERCIAL_HEADING`), sobra só a original no fim. Quando COM split (`fill_split`,
`trim_body!` já vai cortar o documento em dois arquivos de qualquer forma), não remove nada: cada
arquivo (técnica/comercial) fica só com a cópia do seu próprio lado, naturalmente.

**Fonte padronizada: 11 no corpo, 10 em legenda/quadro (2026-09):** pedido do consultor — o
documento inteiro segue fonte Metropolis tamanho 11 (`w:sz="22"`), exceto legendas/quadros e
figuras, que ficam em tamanho 10 (`w:sz="20"`). Isso já era a regra de fato no modelo (herdada de
`w:rPrDefault` em `styles.xml` pro corpo, e run-level explícito pras legendas), então a
"padronização" foi auditar o modelo inteiro contra essa regra em vez de reescrevê-la — achadas
duas inconsistências pontuais, as duas corrigidas por substituição de string crua no
`word/document.xml` (nunca `Nokogiri#to_xml`), sem alterar a contagem de filhos de `<w:body>`
(216→216, só `rPr`, nenhum parágrafo novo/removido):
- A legenda "Quadro 6-1: Produtos a serem entregues." estava sem `w:sz`/`w:szCs` nenhum (saía no
  tamanho herdado de 11, igual corpo) — ganhou `w:sz="20"`/`w:szCs="20"` explícitos nos dois runs,
  igual as legendas irmãs "Quadro 8-1:"/"Quadro 11-1:", que já vinham certas.
- A frase de corpo "Os membros da equipe estão descritos no Quadro 8-1." (parágrafo
  `w14:paraId="63F4339F"`) estava inteira em `w:sz="20"` (10, errado) — era pra ser corpo normal,
  igual a frase irmã "Os produtos... Quadro 6-1." Removido o `w:sz`/`w:szCs` do `pPr` e dos 3
  runs do parágrafo, voltando a herdar o tamanho 11 do documento.

Verificado ao vivo (mesma metodologia de sempre: gerar proposta real via
`GenerateProposalDocumentTool`, converter com LibreOffice headless → PDF → captura de tela) —
confirmado visualmente que a legenda do Quadro 6-1 agora sai visivelmente menor que o corpo (igual
Quadro 8-1/11-1), e que a frase do Quadro 8-1 na seção 8 (EQUIPE TÉCNICA) voltou a sair no mesmo
tamanho das frases ao redor.

**Logo fora do cabeçalho só na página 1 (2026-09):** pedido do consultor — a página 1 (capa, fundo
azul-escuro com a logo grande centralizada no corpo) também carregava a logo pequena do cabeçalho
corrido (`word/header1.xml`, a mesma que aparece em toda página a partir da 2ª). Mecanismo OOXML
padrão do Word pra "primeira página diferente": `<w:titlePg/>` no `<w:sectPr>` do documento, mais
um `<w:headerReference w:type="first">` apontando pra um header PRÓPRIO da primeira página — sem
isso, a página 1 herda o mesmo `type="default"` de todas as outras. Criado `word/header2.xml` (só
usado no `type="first"`) como cópia de `header1.xml` sem o `<w:r>` da logo (`<w:drawing>`), sem
relacionamento de imagem próprio (não precisa, não tem imagem nenhuma) — registrado em
`word/_rels/document.xml.rels` (`rId19`) e `[Content_Types].xml`. Igual toda edição de modelo:
substituição de string crua, nunca `Nokogiri#to_xml`; `<w:sectPr>` continua único (1→1), só ganhou
os dois atributos novos. Teste em `proposal_docx_filler_test.rb` trava que `header2.xml` (página 1)
não tem `<w:drawing>` e `header1.xml` (demais páginas) continua tendo.

**Rodapé próprio pra as páginas PAISAGEM do cronograma (2026-09, relato do consultor "rodapé torto
na paisagem", chat 32).** `word/footer1.xml` monta o "www…"/"Sistema de Gestão…" com dois text
boxes ancorados (`<wp:positionH relativeFrom="column">` + `posOffset` fixo) dimensionados pra
coluna RETRATO (~8504 dxa). Numa página paisagem (coluna ~14002 dxa) esses boxes ficam deslocados
pra esquerda. Criado `word/footer2.xml` = cópia de `footer1.xml` com todo `posOffset` de
`relativeFrom="column"` (|N| > 100k — os dois text boxes + o selo NSI1; o selo redondo em
`posOffset=1` fica) somado de `(14002-8504)/2 × 635` EMU, e os dois `margin-left` das VML
`<v:rect>` fallback somados de 137,45pt. Registrado em `document.xml.rels` (`rId20`),
`[Content_Types].xml`, e `word/_rels/footer2.xml.rels` (cópia — aponta pras mesmas imagens do
selo). `ProposalDocxFiller`: só a variante PAISAGEM (`LANDSCAPE_SECT_XML` / `landscape_refs` no
caminho `insert_schedule_section`) usa `rId20`; o retrato segue no `rId16`. Se um `.docx` gerado
por um modelo ANTIGO passar pelo `insert_schedule_section`, `landscape_refs` não acha `footer2.xml`
e mantém `rId16` (sai levemente torto, mas nunca dangling ref). Teste trava
`footerReference r:id` = `rId16` na quebra retrato e `rId20` na paisagem, e que o modelo traz
`word/footer2.xml`.

**Ao editar o `.docx` do modelo:** os índices das tabelas em
`GenerateProposalDocumentTool#build_tables` são a POSIÇÃO da tabela no documento (0 = revisões,
1 = produtos, 2 = equipe, 3 = desembolso) e têm que ser remapeados se alguma tabela for
adicionada ou removida. A separação técnica × comercial **não** depende mais de índice: é feita
pelo título da seção (`ProposalDocxFiller::FIRST_COMMERCIAL_HEADING`). Editar sempre por
substituição de string crua no XML, nunca `Nokogiri#to_xml`.

**Nunca cortar o documento por índice de filho de `<w:body>`** (foi assim até agosto/2026, e a
proposta PT26011 saiu truncada no meio da seção 7 em produção): o texto que a IA escreve vira
parágrafos de verdade ANTES do corte (`expand_into_paragraphs!`), então o corpo na hora de cortar
tem dezenas de filhos a mais do que o modelo tinha — quanto mais a IA escreve, mais cedo o
documento é cortado. Qualquer fronteira dentro do documento tem que ser localizada por conteúdo.

**O modelo volta re-salvo de tempos em tempos** (a Papyrus abre no Word/LibreOffice para conferir),
e o salvamento muda a forma do XML sem mudar o conteúdo: o estilo dos títulos já veio como
`Ttulo1` e como `Heading1`, e as células vazias das linhas-molde passam a ter run sem `<w:t>`
nenhum. Código que lê o modelo tem que tolerar as duas formas — e teste de geração compara TEXTO
(`//w:t`), nunca a string do XML cru.

**Técnica × Comercial separadas ou juntas:** a IA lê o ET e o TR (quando houver) e sinaliza se algum
deles exige documentos/envelopes separados (comum em licitação pública). O consultor vê essa sugestão na Tela de Precificação/Aprovação
e pode trocar antes de gerar. Conforme a escolha, o sistema gera 1 arquivo (`.docx` único) ou 2
(`proposta_tecnica.docx` + `proposta_comercial.docx`), a partir de modelos `.docx` correspondentes.

O usuário pode pedir ajustes de conteúdo via chat a qualquer momento; a IA gera novo texto estruturado e o backend remonta o(s) DOCX (nova versão).

**Obrigações adicionais da CONTRATANTE/CONTRATADA (2026-08):** as seções 7.1 (obrigações da
Papyrus) e 7.2 (obrigações da contratante) trazem uma lista fixa no modelo — a maioria das
propostas não precisa de mais nada. Quando o ET ou o TR exige algo específico de uma das partes
além disso (ex.: escolta armada pra vistoria, relatório mensal a um órgão financiador), a IA
identifica de que parte é a exigência e passa em `obrigacoes_contratante_adicionais` /
`obrigacoes_papyrus_adicionais` (`GenerateProposalDocumentTool`) — um item por linha, viram itens
novos na mesma lista (`ProposalDocxFiller#expand_into_paragraphs!`, mesmo mecanismo já usado pros
itens não previstos). O modelo tem um item-molde a mais em cada lista, com um placeholder
(`{{OBRIGACOES_CONTRATANTE_ADICIONAIS}}` / `{{OBRIGACOES_PAPYRUS_ADICIONAIS}}`) — quando não há
nada extra, o parágrafo inteiro some (`remove_paragraph_if_blank`), nunca fica um item de lista em
branco no documento.

**Subtópicos numerados no escopo (2026-08):** estudos com divisão temática clara (meio físico,
biótico, socioeconômico, restrições ambientais...) saíam tudo em texto corrido, sem nenhuma
numeração — pedido do consultor pra sair como o resto do documento, "5.1", "5.2" etc. A seção
"ESCOPO E METODOLOGIA DE EXECUÇÃO DO SERVIÇO" é sempre a 5ª de nível 1 do modelo (estrutura fixa,
só o conteúdo muda), então o número é calculado no backend
(`GenerateProposalDocumentTool::SECAO_ESCOPO_NUMERO`) — a IA nunca numera ela mesma, porque não
tem como saber a posição real da seção no documento renderizado. A IA manda os tópicos em
`topicos_escopo` (array "Título | texto"; `escopo_e_metodologia` fica só com os parágrafos
introdutórios, antes dos tópicos); o backend monta "5.N TÍTULO" e o `ProposalDocxFiller` entende
`**texto**` (mesma convenção Markdown que a IA já usa no chat) como um parágrafo em negrito — sem
precisar de um placeholder por tópico, já que a quantidade varia por proposta. Escopo sem divisão
temática (estudo simples) pode deixar `topicos_escopo` de fora e escrever tudo em
`escopo_e_metodologia`, como antes.

**"ITENS NÃO PREVISTOS" virou capítulo independente (2026-09, pedido da Charlene).** Até então era
um bloco no fim do texto do escopo (`**Itens não previstos**` em negrito + lista + a frase fixa de
proposta complementar, tudo dentro de `{{ESCOPO_METODOLOGIA}}`). Agora é a **7ª seção de nível 1**
do modelo (auto-numerada, `numId=1`, logo depois de PRODUTOS), o que empurrou RESPONSABILIDADES
7→8 (e "7.1/7.2" viraram "8.1/8.2", texto literal), EQUIPE 8→9 (`Quadro 8-1`→`9-1`, literal),
PRAZO 9→10 (`SECAO_PRAZO_NUMERO`), VALIDADE 10→11, PREÇO 11→12 (`Quadro 11-1`→`12-1`, literal),
DADOS BANCÁRIOS 12→13. PRODUTOS continua 6 (`Quadro 6-1` intacto), ESCOPO continua 5
(`SECAO_ESCOPO_NUMERO`). O capítulo tem: `{{ITENS_NAO_PREVISTOS}}` (a lista, `- item` por linha,
com a frase introdutória "Não estão contemplados nesta proposta os seguintes itens:" só quando há
item — `GenerateProposalDocumentTool#build_itens_nao_previstos`; vazio → o parágrafo some via
`remove_paragraph_if_blank`) + a frase fixa de proposta complementar, que agora é **texto FIXO do
modelo** (não mais anexada pelo backend — o constante `RESSALVA_PROPOSTA_COMPLEMENTAR` saiu).

**Texto padrão abaixo do Quadro 6-1 (produtos) — atualizado (2026-09):** o parágrafo fixo sobre
formatos de arquivo ganhou "PDF" e `"shapefile" ou "kml"` na lista, e um segundo parágrafo fixo:
"Quando necessário o uso de alguma plataforma para compartilhamento de documentos, será priorizado
a utilização de SharePoint ou OneDrive da Contratante."

**Cronograma (Gantt) em página paisagem, 2 tipos (2026-09):** toda proposta pode ter um
cronograma visual no `.docx`, baseado num exemplo real da Papyrus (`Quadro 9-1`, tabela nativa do
Word com colunas de período agrupadas e barras coloridas por atividade). Dois tipos, sempre
independentes:
1. **Cronograma do Serviço** (`schedule_type: "servico"`) — as atividades do próprio
   estudo/licenciamento (reuniões, campo, protocolos, emissão da licença). Montado em **semanas**
   (Tela de Precificação, sugestão da IA), mas a tabela do `.docx` e o infográfico saem em
   **meses** (2026-09, pedido do cliente — a versão semanal dava 11 páginas; ver "Resumir o
   cronograma" abaixo). Só o `.xml` do MS Project continua semanal.
2. **Cronograma de Implantação do Empreendimento** (`"implantacao"`) — o cronograma da OBRA/
   operação do CLIENTE, não da Papyrus. Em **meses** (pode durar anos — semana ficaria
   ilegível). Só existe quando o ET/TR pede explicitamente, não é padrão em toda proposta.

- **`ScheduleItem`** (`app/models/schedule_item.rb`) — uma linha (fase + atividade) por registro,
  `belongs_to :project_pricing`. Nunca existe uma linha de "fase" separada: o renderer do docx
  detecta troca de `phase_name` entre itens CONSECUTIVOS (por `position`) e insere a linha de fase
  sozinho — mesma convenção já usada pra agrupar produtos por fase de licenciamento
  (`"Licença Prévia (LP):"` em `GenerateProposalDocumentTool#build_tables`).
- **Data de início**: `project_pricing.schedule_papyrus_start_date` /
  `schedule_empreendimento_start_date` (igual `distance_km`/`bdi`, campo escalar direto na
  tabela — não é o caso de N datas pra N parcelas do `payment_schedule`, aqui é só 1 data por
  tipo). Três formas de chegar lá, nessa ordem de prioridade — ver "Sugestão automática..."
  abaixo pro detalhe de cada uma: (1) já digitada na Tela de Precificação; (2) ditada pelo
  consultor no CHAT, capturada por `GenerateProposalDocumentTool`; (3) sem nenhuma das duas,
  o SISTEMA presume o início do mês que vem. A IA nunca INVENTA essa data a partir do
  contexto — ela só repassa a data (2) quando o consultor disse explicitamente, igual
  `nome_arquivo`/`docx_filename_override`; o default (3) é conta determinística em Ruby, não
  IA.
- **A IA sugere, o consultor ajusta** — mesmo padrão de equipe técnica
  (`Proposal#build_with_ai_suggested_team!`), mas sem "menu" fechado (não existe cadastro de fases
  por tipo de estudo, é conteúdo livre). `Proposal#build_with_ai_suggested_schedule!` roda logo
  depois da sugestão de equipe, dentro de `Conversation#ensure_proposal!` — pede um JSON com
  `cronograma_servico`/`cronograma_implantacao` (fase, atividade, período de início, duração,
  `marco: true/false`), grava direto via `ScheduleItem.create!`, sem fallback determinístico (não
  existe "template padrão" de cronograma) — falha ou resposta vazia só significa proposta sem
  cronograma nenhum, o consultor monta na mão se quiser. A Tela de Precificação ganhou uma grade
  editável por tipo (`app/views/proposals/_schedule_section.html.erb`), mesmo padrão de
  fields_for/mini-form de "adicionar linha" da grade de Equipe/Custos externos —
  `ScheduleItemsController` checa `status != "approved"` no próprio controller (diferente de
  `ProposalProfessionalsController`/custos externos, que só escondem os controles na view; decisão
  consciente de não repetir esse gap num controller novo).
- **`ScheduleTableBuilder`** (`app/services/schedule_table_builder.rb`) — gera o XML de UM
  `<w:tbl>` a partir de `items` (já ordenados por `position`) + `start_date` + `unit` (`:week`/
  `:month`). Cores/estrutura exatas do exemplo real: cabeçalho de 2 linhas (grupo de mês/ano em
  `1F4E79`, período em `2F5597`), linha de fase em `D9E1F2` (sem barra, cor de texto `1F4E79`),
  linha de atividade com zebra `auto`/`F2F5F9` nas células sem barra e `2E75B6` (ou `C65911` se
  `milestone`) nas células dentro de `[start_period, start_period+duration_periods)`.

  **Muitos períodos numa página só (2026-09, achado ao vivo):** um cronograma de serviço real de
  ~2 anos (104 semanas, sugerido pela própria IA pra um monitoramento contínuo) deixava cada
  coluna tão fina que o cabeçalho ("Sem 1"/"Setembro 2026") quebrava letra por letra, empilhado —
  ilegível. Duas camadas de correção, as duas testadas ao vivo (LibreOffice headless → PDF →
  captura de tela, não só o XML):
  1. **Gira o cabeçalho 90°** (`ROTATE_BELOW_WIDTH = 500` dxa) quando a coluna fica estreita
     demais pra ficar horizontal — célula mantém a largura, só o texto passa a correr de baixo
     pra cima (`<w:textDirection w:val="btLr"/>`).
  2. **Consolida períodos em blocos** (`MIN_COLUMN_WIDTH = 400` dxa, ver `bucket_size`/
     `display_periods`) quando nem girado um período sozinho caberia — 4 semanas viram 1 coluna
     ("Sem 1-4"), o `start_period`/`duration_periods` de cada atividade é remapeado pro(s)
     bucket(s) que cobre. Sem isso, mesmo com o texto girado, o LibreOffice simplesmente **não
     desenhava nada** abaixo de ~300dxa — largura mínima real pra QUALQUER texto rotacionado
     numa célula, giro não é de graça.
  3. **Pegadinha que mascarou a correção nº 1 por um tempo**: `w:textDirection` segue uma ORDEM
     fixa dentro de `<w:tcPr>` no schema OOXML (depois de `tcBorders`/`shd`, antes de `vAlign`)
     — fora de ordem, o Word/LibreOffice **ignora o elemento em silêncio**, sem erro nenhum; o
     cabeçalho continuava quebrando letra por letra como se `rotate:` nunca tivesse sido passado.
  4. **Pegadinha que mascarou a nº 2**: mesmo com largura/ordem corretas, o texto girado saía em
     branco no documento REAL (mas funcionava num `.docx` isolado de teste, sem o modelo da
     Papyrus). Causa: o modelo define `w:pPrDefault` com `spacing after="160"` — invisível num
     parágrafo normal, mas depois de girar 90° essa folga vertical vira LARGURA extra que a
     célula não tem. `cell_xml` agora sempre escreve `<w:spacing before="0" after="0" line="240"
     lineRule="auto"/>` explícito, nunca herda o padrão do documento.
- **Inserção no `.docx`** (`ProposalDocxFiller#insert_schedule_tables!`) — âncora pelo token
  `{{PRAZO_EXECUCAO}}` (ainda intacto, roda antes de `fill_simple_placeholders!`), nunca por
  índice de `<w:body>`. Mecânica de seção OOXML: um parágrafo com `<w:sectPr>` fecha a seção que
  TERMINA nele (não a que começa depois) — bastam 2 parágrafos novos (um retrato, fecha a seção
  que já existia sem mudar nada nela; um paisagem, fecha a seção das tabelas) pra abrir e fechar o
  bloco paisagem; o resto do documento (VALIDADE DA PROPOSTA em diante, até o bloco de assinatura)
  volta pro retrato sozinho, herdando do `<w:sectPr>` final que já existe no corpo. "PRAZO DE
  EXECUÇÃO" é sempre a **10ª** seção de nível 1 do modelo (era a 9ª até 2026-09 — "ITENS NÃO
  PREVISTOS" virou capítulo, ver abaixo; estrutura fixa, mesmo princípio de `SECAO_ESCOPO_NUMERO`),
  por isso o número do quadro (`Quadro 10-1`/`Quadro 10-2`, `ProposalDocxFiller::SECAO_PRAZO_NUMERO`)
  é calculado no backend, nunca pela IA.
  **Achado ao vivo, corrigido**: a tabela nova nasce ENTRE a de equipe (índice posicional 2) e a
  de desembolso (índice 3) — inseri-la ANTES do `tables.each` de `build` deslocava `//w:tbl[3]`
  pra apontar pra ela em vez do Desembolso, e `fill_table!` reescrevia o cronograma por cima com
  as linhas de pagamento. Corrigido preenchendo as tabelas originais por posição PRIMEIRO, com a
  tabela de cronograma entrando só depois — a ordem de inserção deixa de importar pros índices.
- **`GenerateProposalDocumentTool#build_schedules`** lê `project_pricing.schedule_items` +
  `schedule_*_start_date` direto do banco (igual equipe/desembolso, nunca um parâmetro que a IA
  preenche a cada geração) e passa pra `ProposalDocxFiller#fill`/`fill_split` como `schedules:`.
  Um tipo com itens mas sem data fica de fora do `.docx` (a página só existe quando os dois estão
  presentes) — mas deixou de ser silencioso pro consultor, ver "Sugestão automática" abaixo.
  Sai igual em qualquer status da proposta (draft/priced/approved), sempre na parte técnica — não
  é dado de preço.
- **Bloco de assinatura em negrito** no fim do documento (Papyrus + cliente, CNPJ) já existia no
  modelo e já saía em negrito antes desta funcionalidade — confirmado ao vivo que continua intacto
  depois da página paisagem nova, sem precisar de nenhuma mudança própria.

**Sugestão automática na hora de gerar + acervo histórico como referência (2026-09):** antes,
`build_with_ai_suggested_schedule!` só rodava UMA VEZ, na criação da proposta
(`Conversation#ensure_proposal!`) — se falhasse ou viesse vazia (faltava informação naquele
momento; TR/complementar chegou depois), a proposta ficava sem cronograma pra sempre, sem
ninguém saber por quê. `GenerateProposalDocumentTool#ensure_schedule_suggested!` agora tenta de
novo TODA vez que o consultor pede pra gerar o documento, mas só quando ainda não existe NENHUM
item — idempotente, nunca reescreve por cima do que o consultor já ajustou na Tela de
Precificação. **Enfileira `SuggestScheduleJob` em vez de chamar a IA direto** — ver "Sugestão de
cronograma tem que rodar em BACKGROUND" mais abaixo pro porquê (reentrância em `Conversation#
complete`), achado ao vivo depois da primeira versão desta funcionalidade. `fetch_ai_schedule_
suggestion` também passou a registrar `SearchHistoricalArchiveTool`
quando há acervo indexado (`HistoricalProposalChunk.embedded.exists?`), mesmo padrão do
`ProcessLegalNormsJob` (`conversation.with_tool(...)` direto, antes de `ask_internally` — dali em
diante `Conversation#ask_internally` já registra sozinho) — a IA pode consultar como a Papyrus
estruturou o cronograma em projetos parecidos antes de sugerir fases/durações, sempre como
referência, nunca fonte de datas.

**Data de início: ditada no chat, ou presumida (2026-09):** antes, sem data na Tela de
Precificação o tipo simplesmente saía do documento em silêncio (só um aviso no retorno da
ferramenta). Dois parâmetros novos em `GenerateProposalDocumentTool` —
`data_inicio_cronograma_servico`/`data_inicio_cronograma_implantacao` — deixam o consultor
DITAR a data no chat ("o cronograma começa em 15/10"); `apply_schedule_start_date_overrides!`
grava direto em `project_pricing` quando a IA manda o parâmetro (mesmo padrão de
`nome_arquivo`/`docx_filename_override` — só quando ele disse algo explicitamente, nunca
inventado). Se depois disso ainda não houver data pra um tipo que TEM itens,
`default_missing_schedule_dates!` presume o **início do mês que vem** (`Date.current.next_month.
beginning_of_month`) — conta determinística do sistema, não a IA "adivinhando" pelo contexto,
mesma distinção de sempre entre motor de regras e IA. Nunca sobrescreve uma data que já existe
(nem a da Tela, nem uma dita antes). **Continua sem bloquear a geração do documento** — o
cronograma sempre entra (com a data que tiver: já cadastrada, ditada agora, ou presumida), e
`schedule_message` avisa na mensagem de retorno quando presumiu, com a data usada por extenso,
pra IA repassar ao consultor no chat — nunca uma pergunta livre da IA, sempre o mesmo aviso
determinístico, e sempre corrigível gerando de novo (com a data certa no chat, ou editando na
Tela de Precificação).

**Sugestão de cronograma tem que rodar em BACKGROUND, nunca síncrona dentro da tool call
(2026-09, achado ao vivo na conversa 32/proposta 18):** `GenerateProposalDocumentTool` só é
chamada como tool call DENTRO de `Conversation#complete` (`RespondToMessageJob#perform` chama
`conversation.complete` direto, sem `with_ai_lock`). A primeira versão de
`ensure_schedule_suggested!` chamava `Proposal#build_with_ai_suggested_schedule!` (que por sua
vez chama `conversation.ask_internally` → `with_ai_lock` → `complete`) **de dentro** dessa tool
call — ou seja, reentrava `Conversation#complete` enquanto a chamada de fora ainda estava no meio
da PRÓPRIA tool call. Sintoma reproduzido ao vivo: a chamada de verdade pro Bedrock falhava
sozinha (`WARN -- RubyLLM: RubyLLM: API call failed, destroying message: <id>`), **sem soltar
nenhuma exceção** que o `rescue StandardError` de `build_with_ai_suggested_schedule!` pudesse
pegar — o cronograma ficava com 0 itens pra sempre, e como não existe fallback determinístico pra
cronograma (diferente da equipe, que cai em `build_from_template!`), o problema nunca foi mascarado:
4 gerações seguidas na conversa 32, todas com `schedule_items.count == 0`.

**Correção**: `ensure_schedule_suggested!` nunca mais chama a IA direto — só enfileira
`SuggestScheduleJob` (`app/jobs/suggest_schedule_job.rb`, idempotente, mesma checagem de "só
tenta se ainda não há item nenhum") e devolve `true`/`false` dizendo se enfileirou, pra
`schedule_message` avisar o consultor ("Estou sugerindo o cronograma em segundo plano — peça pra
gerar de novo em instantes"). O job roda inteiramente FORA do turno de chat que o disparou — sem
nenhum `complete()` em andamento no meio do caminho — e testado ao vivo com o Solid Queue de
verdade rodando (não só `perform_now` isolado): o job pegou a fila sozinho, a chamada ao Bedrock
teve sucesso, os 14 itens saíram certos.

**Confirmada e corrigida a mesma causa-raiz em `Conversation#ensure_proposal!` (2026-09,
achado em produção: conversas 32/33/34 — "não saiu o .mpp no chat").** Logs reais de produção
mostraram o quadro completo: na primeira geração de cada proposta (`ensure_proposal!` chamado de
dentro da MESMA tool call), `build_with_ai_suggested_schedule!` reentrava e derrubava a chamada ao
Bedrock (`tool_use ids were found without tool_result blocks`) — e o dano ficava: a mensagem
corrompida no meio do histórico fazia o `complete()` DE FORA (o turno inteiro do
`RespondToMessageJob`) falhar também, logo depois (`toolResult blocks... exceeds toolUse blocks`).
O `.docx` às vezes saía (o `rescue` de `build_with_ai_suggested_schedule!`/`build_with_ai_suggested_
team!` engolia o erro e a ferramenta terminava normal), mas a resposta da IA nunca chegava ao
consultor — o job morria com `RespondToMessageJob failed`, e o chat mostrava só a bolha de erro
genérica. **Equipe estava exposta ao mesmo problema**, só que mascarada pelo fallback
determinístico (`build_from_template!`) — silenciosa, muito mais difícil de notar do que
cronograma vazio.

**Correção**: `ensure_proposal!` ganhou `ai_suggestions:` (default `true`). Quando `false` — é o
que `GenerateProposalDocumentTool#execute` sempre passa agora
(`ensure_proposal!(ai_suggestions: false)`) — a equipe vem direto de `build_from_template!`
(determinístico, sem IA, MESMO resultado que já saía quando a sugestão falhava) e o cronograma
fica de fora (cuidado pelo `ensure_schedule_suggested!` logo depois, que enfileira em background).
Zero chamada de IA acontece dentro da tool call inteira, então zero reentrância. Quem chama pelo
controller (`ProposalsController`, botão "Avançar para Precificação", fora de qualquer
`complete()` em andamento) continua usando o padrão `true` — ali é seguro, e o consultor espera
ver a equipe já sugerida pela IA ao abrir a Tela de Precificação na hora.

Verificado ao vivo reproduzindo o cenário exato de produção (conversa real, sem proposta ainda,
`RespondToMessageJob.perform_now` de verdade): a proposta nasceu, o `.docx` saiu, e — a
diferença que importa — a resposta de sucesso da IA chegou normal no chat, sem nenhum
`RubyLLM::BadRequestError`. Equipe conferida como vindo do template (`0h` default, não da IA);
`SuggestScheduleJob` enfileirado e, rodado à parte, criou os itens de cronograma sem erro
nenhum — confirma que separar as duas chamadas (equipe síncrona-porém-sem-IA, cronograma
assíncrono) resolve os dois lados do bug de uma vez.

**Efeito colateral achado ao limpar o teste ao vivo:** a checklist interna
(`Conversation::PROPOSAL_CHECKLIST_INSTRUCTIONS`, item 12) ainda dizia "não temos suporte
estruturado" pra cronograma — texto de antes desta funcionalidade existir, nunca atualizado.
Isso fazia a IA ativamente EVITAR mencionar/pedir cronograma pro consultor, mesmo com o sistema já
suportando. Corrigido o texto do item 12 pra descrever o fluxo automático atual. Como esse texto
vira uma `Message` gravada no início de CADA conversa (não é recalculado depois), conversas já
existentes continuam com a versão antiga até serem recriadas — não há como "atualizar" uma
conversa já em andamento a não ser editando a mensagem na mão (feito manualmente na conversa 32
pra verificação).

**Terceira causa-raiz da MESMA família, agora entre DOIS PROCESSOS, não um só (2026-09, achado
em produção: conversa 35/proposta 21 — "não saiu o cronograma").** As duas correções acima
eliminaram toda reentrância DENTRO do mesmo processo (mesma chamada de Ruby reentrando
`Conversation#complete`). Mas `RespondToMessageJob#perform` chama `conversation.complete` **sem
nenhuma trava** — e `SuggestScheduleJob`, que `ensure_schedule_suggested!` enfileira de DENTRO da
tool call de `generate_proposal_document` (ou seja, depois que RubyLLM já gravou a mensagem de
`tool_use` dessa chamada, mas ANTES do `tool_result` dela ser gravado — isso só acontece quando a
ferramenta TERMINA de executar), pode ser pego por outro worker do Solid Queue **nesse
intervalo**, um processo totalmente diferente do que está rodando o turno principal. A chamada de
dentro do job (via `ask_internally`, que já usa `with_ai_lock`) lia o histórico da conversa nesse
estado — último bloco era um `tool_use` sem `tool_result` correspondente — e o Bedrock rejeitava:
`messages.N: 'tool_use' ids were found without 'tool_result' blocks immediately after`. Mesmo
sintoma de sempre (RubyLLM destruía a mensagem que estava criando, cronograma ficava com 0 itens
pra sempre), causa nova: não é MAIS reentrância de processo, é corrida ENTRE processos pela mesma
conversa, e nada do que já tinha sido corrigido protegia contra isso — `with_ai_lock` sempre
serializou `ask_internally` contra `ask_internally`, nunca contra um `#complete` cru chamado de
fora dele.

**Correção**: `Conversation#complete_with_lock` (`with_ai_lock { complete }`) — `RespondToMessageJob`
troca `conversation.complete` por isso. Como nada dentro do turno principal chama `ask_internally`
de forma síncrona (foi exatamente essa a eliminação das duas correções anteriores), colocar o
turno inteiro dentro do mesmo `pg_advisory_xact_lock` é seguro: não reentra a trava no mesmo
processo (mesma sessão do Postgres, reentrante por natureza), só faz um job de OUTRO processo
(`SuggestScheduleJob`, ou qualquer `ask_internally` futuro) esperar o commit da transação deste
turno antes de ler o histórico — mesmo princípio de sempre (`with_ai_lock`), só que finalmente
aplicado nos DOIS lados que escrevem na mesma conversa, não só num. `GeneralChat` não precisou do
mesmo tratamento: nenhum job hoje chama `ask_internally` numa `GeneralChat` em paralelo com
`RespondToGeneralChatMessageJob` (vale reavaliar se isso mudar).

Testado com o mesmo método dos outros testes de `with_ai_lock`
(`test/models/conversation_ai_lock_test.rb`, threads com conexão de banco real cada uma, não a
transação compartilhada dos testes normais): confirmado que o teste FALHA de forma confiável (3/3
rodadas) chamando `#complete` cru em vez de `#complete_with_lock`, e passa de forma confiável
(3/3) com a correção — prova que o teste pega a regressão de verdade, não só documenta a
intenção.

**Quarta causa-raiz da MESMA família: dois jobs concorrentes pra MESMA proposta, não mais um
processo disputando com outro (2026-09, relato do consultor: "pedi no chat 32 pra fazer o
cronograma e saiu muita coisa repetida").** As três correções acima eliminaram toda reentrância
(mesmo processo) e toda corrida entre um `#complete` cru e um `ask_internally` concorrente
(processos diferentes, mesma conversa). Mas nada até aqui impedia DOIS `SuggestScheduleJob`
enfileirados pra MESMA proposta de rodarem ao mesmo tempo — `GenerateProposalDocumentTool#
ensure_schedule_background_work!` enfileira um sempre que `pricing.schedule_items.exists?` é
`false` NA HORA da checagem, e essa checagem roda de novo a CADA geração pedida no chat. Dados
reais da proposta 18 (conversation 32): duas chamadas de "gerar documento" a **~40 segundos** de
distância (`22:40:21`/`22:41:01`) — tempo mais que suficiente pra uma chamada de IA ainda não ter
terminado — enfileiraram dois `SuggestScheduleJob`, os dois viram `schedule_items.exists? ==
false` (nenhum tinha inserido nada ainda) e **os dois rodaram
`build_with_ai_suggested_schedule!` em paralelo**, cada um com sua própria chamada de IA. O
resultado não foi a mesma lista inserida duas vezes — foram **duas sugestões de cronograma
inteiras, com paráfrases diferentes pra cada atividade**, intercaladas na tabela porque
`apply_schedule_lines!` sempre grava `position` a partir de 0 (índice do array daquela chamada),
nunca olhando quantos itens já existem: `schedule_items` da proposta 18 tinha 34 linhas, sendo
posição 0 a 17 cada uma duplicada (uma vez às `22:41:17`, outra às `22:41:27` — os dois jobs
rodaram 10s um do outro, os dois terminando a própria chamada de IA antes de qualquer verificação
acontecer de novo). Mesma família de bug (checagem "já existe?" feita ANTES de uma chamada de IA
que demora dezenas de segundos, sem nada travando o intervalo entre checar e escrever), quarta
causa diferente: agora é concorrência entre jobs de BACKGROUND pra mesma proposta, não mais
conversa/processo.

**Correção**: `Proposal#with_schedule_lock` — mesmo mecanismo de sempre
(`pg_advisory_xact_lock`, libera sozinho no commit/rollback), mas com **namespace próprio** (a
forma de 2 argumentos, `pg_advisory_xact_lock(classid, objid)`, com um `classid` fixo só pra isso)
em vez de reusar a chave de `Conversation#with_ai_lock` — id de proposta e id de conversa são
sequências independentes que podem coincidir numericamente (a proposta 18 já é filha da
conversa 32; um dia poderiam ser o mesmo número em lados diferentes de propósitos diferentes, e aí
a trava erraria de travar coisa demais). `SuggestScheduleJob` e `ElectScheduleKeyPointsJob` agora
envolvem a checagem "já existe?"/"já elegeu?" **e** a chamada de IA dentro do mesmo
`with_schedule_lock`: quem chega primeiro trava a proposta inteira até terminar (checagem +
IA + escrita, tudo dentro da mesma transação); quem chega depois espera o commit e só então repete
a própria checagem — agora vendo o resultado de verdade, e desiste.

**Pegadinha achada escrevendo o teste, corrigida**: `ElectScheduleKeyPointsJob` guardava
`pricing = proposal.project_pricing` (association `has_one`, memoiza o registro em Ruby) **antes**
de entrar na trava — a segunda chamada, ao acordar depois do commit da primeira, ainda enxergava
`schedule_key_points` como estava ANTES de qualquer uma rodar (o objeto em memória nunca foi
reconsultado), e chamava a IA de novo à toa. Corrigido com `proposal.project_pricing.reload`
**depois** de adquirir a trava. `SuggestScheduleJob` não tem o mesmo problema: a checagem ali é
`schedule_items.exists?` numa association `has_many`, que sempre bate no banco (nunca usa o cache
de Ruby de uma leitura anterior), então funciona certo mesmo com `project_pricing` carregado antes
da trava — os dois casos ficaram documentados um do lado do outro nos jobs pra não alguém
"simplificar" um copiando o padrão errado do outro.

Testado com o mesmo método das corridas anteriores
(`test/jobs/schedule_lock_test.rb`, threads com conexão de banco real cada uma, não a transação
compartilhada dos testes normais, `Conversation#complete` redefinido com um `sleep` proposital pra
abrir a janela da corrida): duas chamadas concorrentes de `SuggestScheduleJob` pra mesma proposta
produzem **1** cronograma, não 2; duas chamadas concorrentes de `ElectScheduleKeyPointsJob`
resultam em **1** chamada de IA, não 2 — os dois testes falhavam de forma confiável sem
`with_schedule_lock`/`.reload` e passam com a correção.

**Exportação em MSPDI pro MS Project (2026-09):** um cronograma presente PODE sair também como um
arquivo `.xml` à parte, no formato **MSPDI** (o XML de intercâmbio do MS Project — Arquivo > Abrir
importa como projeto completo: fases, atividades, datas, marcos). **Não é o binário `.mpp` de
verdade** — gravar esse formato não é viável em nenhuma linguagem fora de produtos pagos .NET/Java
(a Microsoft nunca documentou escrita, só engenharia reversa parcial pra leitura); MSPDI é o
caminho padrão de qualquer integração séria.

**Sob demanda, não em toda geração (2026-09, pedido do consultor).** Nasceu saindo sempre que
havia cronograma; a maioria das propostas nunca chega a ser importada em nenhum MS Project, então
o arquivo saía à toa quase sempre. `GenerateProposalDocumentTool` ganhou o parâmetro
`exportar_cronograma_ms_project` (boolean, `required: false`) — a IA só marca `true` quando o
consultor pede explicitamente no chat ("manda também em .xml"), ou quando o ET/TR exige entrega
nesse formato; sem isso, `#export_ms_project?` (`ActiveModel::Type::Boolean`, ausência/`nil` conta
como `false`) mantém `attach_schedule_mspdi_files!` fora de jogo e `schedule_filenames` fica `[]`
— nada de MSPDI, nada de menção a "MS Project" na mensagem de retorno (`schedule_message` só fala
nisso quando `schedule_filenames.present?`). A tabela do cronograma dentro do próprio `.docx`
(`Quadro N-1`, ver acima) **nunca** depende disto — sai sempre, com ou sem o `.xml`. Decisão por
geração, não fica "lembrada": cada chamada da ferramenta decide de novo a partir do que está
acontecendo NAQUELA conversa, então pedir uma vez não faz o `.xml` sair de novo sozinho nas
próximas gerações — o consultor pede de novo se quiser outra versão dele.
- **`app/services/schedule_mspdi_exporter.rb`** monta o payload (fase = tarefa-resumo, atividades
  = tarefas-filhas, 1 nível só, mesmo agrupamento por `phase_name` consecutivo do
  `ScheduleTableBuilder`) e delega a montagem do `org.mpxj.ProjectFile`/gravação pra um helper Java
  próprio — **`lib/java/ScheduleToMspdi.java`**, compilado por `bin/build_java_helpers` e
  **versionado já compilado** (`lib/java/build/ScheduleToMspdi.class`, mesmo princípio do `.docx`
  do modelo: binário íntegro no repo) — produção só precisa de JRE (`java`), nunca de JDK/`javac`.
  Reaproveita os `.jar` que a gem `mpxj` (Jon Iles, o próprio autor/mantenedor da biblioteca MPXJ)
  já vendoriza — essa gem em si só tem API de LEITURA em Ruby (`MPXJ::Reader`), escrita usa os
  mesmos `.jar` chamados direto via `java -cp`.
- Datas em dias corridos (sem calendário de dias úteis) — mesma convenção do
  `ScheduleTableBuilder`, nenhuma conta de dia útil entra em lugar nenhum do cronograma. A fase
  (tarefa-resumo) tem `start`/`finish` calculados no Ruby a partir do min/max das atividades —
  MPXJ não faz rollup sozinho aqui, o Java só recebe datas já prontas.
- `GenerateProposalDocumentTool#attach_schedule_mspdi_files!` roda DEPOIS do(s) `attach!` do
  `.docx` (pra `generated_documents.first` continuar sendo o `.docx` — testes e a própria Tela de
  Precificação assumem essa ordem), um arquivo por tipo presente, nomeado a partir de
  `Proposal#schedule_filename` (mesma base do nome da proposta técnica + sufixo
  `_Cronograma_Servico`/`_Cronograma_Implantacao` + `.xml`). Falha do helper Java (ex.: JRE
  ausente no servidor) não derruba a geração do `.docx` — só fica sem o arquivo extra, e agora
  **avisa o consultor na própria mensagem de retorno** (`GenerateProposalDocumentTool#
  schedule_message`, achado ao vivo: antes a falha só ia pro log do servidor, o consultor nunca
  sabia que o `.xml` não tinha saído). Aparece sozinho na lista de "Documentos gerados" da Tela de
  Precificação (`generated_documents` é genérico, qualquer content-type).
- Verificado com round-trip de verdade (não só "o XML parece certo"): gera o MSPDI e relê com o
  próprio `MPXJ::Reader` da gem, conferindo hierarquia/datas/marcos batendo — mesma disciplina de
  testar via LibreOffice pro `.docx`, aqui o "abridor de referência" é a própria MPXJ.
- **CI** (`.github/workflows/ci.yml`, jobs `test`/`system-test`) ganhou `default-jre-headless` no
  `apt-get install` — só JRE, o `.class` já vem pronto do repo.

**Atrito de importação no MS Project desktop (2026-09, relato do consultor).** `.mpp` de verdade
continua fora de alcance (a MPXJ 16.7 só tem writer de MSPDI/MPX/Planner/Primavera/SDEF — nenhum
de `.mpp`; o binário só sai do próprio Project ou de lib paga tipo Aspose.Tasks). O que incomoda
não é o formato e sim dois passos que o usuário não conhece: (1) clicar duas vezes no `.xml` não
abre no MS Project (o Windows não associa `.xml` a ele — vai pro navegador); (2) em Arquivo >
Abrir o arquivo nem aparece sem trocar o tipo de "Projetos" pra "Formato XML (*.xml)" na caixinha
embaixo do nome. Duas frentes, sem tocar no formato:
- `GenerateProposalDocumentTool#schedule_message` passou a dar o passo a passo exato no chat (tipo
  de arquivo → "Como um novo projeto" → clicar duas vezes não abre).
- `ScheduleMspdiExporter#with_import_note` injeta a mesma instrução como **comentário XML logo
  depois da tag `<Project>`** — visível pra quem acaba abrindo o `.xml` num editor/navegador.
  DEPOIS de `<Project>`, nunca antes: comentário antes da raiz quebra a auto-detecção de formato
  da MPXJ ("Unsupported file type") e o que a MPXJ recusa uma versão de Project também pode
  recusar. Teste no `schedule_mspdi_exporter_test.rb` trava que o comentário está lá E que a MPXJ
  ainda relê o arquivo.

**Inserir só o cronograma num `.docx` finalizado por fora (2026-09, pedido do consultor).** Caso
real: a proposta foi gerada pelo sistema, revisada no Word por fora, e o consultor quer só a
seção de cronograma (tabela `Quadro 9-N` + infográfico, página paisagem) de volta nesse `.docx`,
sem refazer o documento inteiro. `GenerateProposalDocumentTool` só monta o `.docx` do zero a
partir do modelo — não servia.
- **`ProposalDocxFiller#insert_schedule_section(docx_bytes, schedules:)`** — abre o `.docx` do
  consultor (não o modelo), roda só `schedule_block_xml` (o mesmo que `#insert_schedule_tables!`
  usa — infográfico + legenda + tabela, entre duas quebras de seção retrato/paisagem) e devolve
  os bytes. `schedules` no mesmo formato de `#fill`. Ancora pelo TÍTULO "PRAZO DE EXECUÇÃO"
  (`SCHEDULE_ANCHOR_HEADING`, o token `{{PRAZO_EXECUCAO}}` não existe num `.docx` finalizado) —
  insere logo antes do próximo Título 1. Sem essa seção → `SectionAnchorError` (a ferramenta
  traduz numa mensagem de chat). **Se o `.docx` já tem um bloco de cronograma** (legenda "Quadro
  9-N"), REMOVE o bloco paisagem antigo — dos dois parágrafos com `<w:sectPr>` que o cercam — e
  põe o novo no lugar, pra não sair cronograma duplicado (o `.docx` gerado pelo sistema quase
  sempre já tem um). As props de seção (cabeçalho/rodapé) vêm do `<w:sectPr>` final do PRÓPRIO
  `.docx` enviado (`sect_props_from_xml`, string, não Nokogiri) — um "Salvar como" no Word pode
  ter renumerado os `r:id` do `rId15`/`rId16` do modelo.
- **`InsertScheduleSectionTool`** — registrada em `RespondToMessageJob` só quando
  `conversation.proposal` existe. Acha o `.docx` mais recente anexado na conversa (padrão de
  `LearnFromRevisedProposalTool#latest_attachment`, só `.docx`), pega o cronograma direto do
  `project_pricing` (gêmeo de `GenerateProposalDocumentTool#build_schedules`/`#schedule_payload`),
  presume início do mês que vem pra data ausente (mesma regra determinística), chama
  `insert_schedule_section` e anexa o resultado em `generated_documents`
  (`kind: "revised_with_schedule"`). Sem `schedule_items` nenhum → enfileira `SuggestScheduleJob`
  e pede pra tentar de novo (nunca chama IA síncrono, mesmo motivo de sempre). Devolve o formato
  `{ success:, version:, filenames:, message: }` que o card de download do chat já entende.
- Verificado ao vivo (gerar `.docx` sem cronograma pelo modelo → `insert_schedule_section` →
  LibreOffice → PDF → captura): bloco paisagem com infográfico + `Quadro 9-1` + tabela entra
  logo depois de "PRAZO DE EXECUÇÃO", cabeçalho/rodapé preservados, resto do documento intacto;
  rodar 2× não duplica.

**"Documento gerado só aparece depois de F5, às vezes" (2026-09, relato do consultor).** Toda tool
call roda DENTRO da transação do `with_ai_lock` (`Conversation#complete_with_lock`, ver acima). O
`GenerateProposalDocumentTool#attach!` disparava `@conversation.broadcast_refresh` de lá de dentro
— o navegador recebia o refresh e re-buscava a página ANTES do commit da transação, via o estado
velho (sem o arquivo novo), e nada re-broadcastava depois do commit. Intermitente: às vezes a
re-busca ganhava a corrida do commit, às vezes não. `InsertScheduleSectionTool` nem broadcastava.
**Correção**: o `broadcast_refresh` saiu das tool calls; `RespondToMessageJob` guarda a contagem
de `proposal.generated_documents` ANTES do turno e, DEPOIS de `complete_with_lock` retornar (já
commitado), dispara UM `broadcast_refresh` (morph — já traz mensagens novas + a sidebar
"Documentos") se a contagem cresceu, em vez do append por mensagem. Teste no
`respond_to_message_job_test.rb` (stub de `#complete` que anexa um doc → espera `action: "refresh"`
e nenhum `append`) e no `generate_proposal_document_tool_test.rb` (a tool NÃO broadcasta sozinha).

**Bug achado ao vivo, corrigido: `Duration` tinha que ser `TimeUnit.ELAPSED_DAYS`, não
`TimeUnit.DAYS` (2026-09).** O arquivo abria certo no MPXJ (round-trip acima passava) mas as
datas saíam TORTAS de verdade dentro do MS Project — "funciona mas é difícil de usar/confiar".
Causa: toda tarefa nasce auto-agendada (`Manual=0`, padrão de `project.addTask()`), e o Project
**recalcula** `Start + Duration` pelo calendário da tarefa assim que abre o arquivo — o calendário
"Standard" que `project.addDefaultBaseCalendar()` cria é seg-sex, 8h/dia. `TimeUnit.DAYS` é dia
**útil** nessa conta; `Start`/`Finish`, por outro lado, sempre foram calculados em dias
**corridos** (convenção deliberada, ver acima) — as duas contas divergem sempre que a atividade
atravessa um fim de semana, cada vez mais quanto mais fins de semana ela atravessar (medido:
73 dias de desvio num cronograma de implantação de 6 meses). `MPXJ::Reader`, usado no teste
automatizado, não pega isso: ele só relê os bytes já gravados, sem rodar esse recálculo de
calendário — por isso o teste sempre passou apesar do bug. Corrigido trocando
`TimeUnit.DAYS` por `TimeUnit.ELAPSED_DAYS` (`lib/java/ScheduleToMspdi.java`) — duração elapsed
ignora calendário, `Start + Duration` bate com o `Finish` em qualquer dia da semana, com ou sem
recálculo. Confirmado empiricamente (não só lido no código): a mesma entrada de 7 dias corridos
gravava `PT56H0M0S` (56 horas ÚTEIS = 7×8h) antes da correção e passa a gravar `PT168H0M0S`
(168 horas CORRIDAS = 7×24h) depois — `test/services/schedule_mspdi_exporter_test.rb` ganhou um
teste que verifica `Task#duration` (segundos) exatamente por isso, porque é o jeito de pegar essa
regressão sem precisar simular o motor de CPM do Project. Efeito colateral corrigido junto:
marco (`milestone: true`) agora sai sempre com duração **zero** no MSPDI (convenção do MS
Project), independente de `duration_periods` (que continua `>= 1`, é regra do Gantt do `.docx`,
não desta exportação) — antes todo marco saía com 1 período de duração, e ficava deslocado depois
do Project recalcular.

**Infográfico de linha do tempo (2026-09):** além do `Quadro 9-1` (tabela nativa do Word,
auditável, todas as fases/atividades), toda proposta com cronograma ganha também um resumo
VISUAL — círculo numerado + ícone + linha conectando + título e duração em dias por ponto
(sem data — pedido do consultor, 2026-09; ponto de span 0 mostra "-" no lugar da duração), pedido
pelo consultor com uma referência de uma proposta real da Papyrus. Os dois convivem no documento
(o infográfico entra ANTES da legenda+tabela do mesmo tipo) — o infográfico é o resumo que o
cliente vê de cara, a tabela continua sendo a fonte de detalhe auditável.

- **`app/services/schedule_timeline_renderer.rb`** — gera SVG cru (mesmo estilo de
  `AreaSketchRenderer`: heredoc + método privado por elemento, sem gem de gráficos) e
  **rasteriza pra PNG antes de devolver**, via `rsvg-convert` (pacote de sistema `librsvg2-bin`,
  não é gem Ruby — mesmo padrão de "shell pra binário externo, sem bloquear o resto se faltar"
  já usado pro helper Java do MSPDI e pro `pdftoppm`/`tesseract` do OCR do RAG). SVG nunca chega
  no `.docx` neste projeto — o `[Content_Types].xml` do modelo só declara PNG/JPG, mesma decisão
  já tomada pro croqui do KMZ (`GenerateProposalDocumentTool#build_images`) — e continua sendo,
  em vez de ensinar o filler a lidar com blip duplo de SVG nativo do Word sem necessidade.
- **≤6 marcos que a IA elege, ou um círculo por FASE como fallback** (2026-09, pedido do cliente
  — antes era um por ATIVIDADE, e um cronograma de 34 atividades virava 3 imagens paisagem
  "gigantes"; a linha do tempo é resumo executivo, o detalhe fica na tabela e no MS Project).
  - **Caminho preferido — `key_points`**: o cronograma do serviço mostra os **≤6 MARCOS mais
    importantes** que a IA elegeu (`project_pricings.schedule_key_points`, jsonb
    `[{ "nome", "periodo" }]` — semana 1-based). Cada marco N vira um círculo cujo "X dias" é a
    **duração do trecho** que ele cobre (do marco N-1 até ele; o 1º conta desde a semana 1 —
    `ScheduleTimelineRenderer#key_points_to_segments`). `periodo` é clampado contra o fim real do
    cronograma, então editar os `schedule_items` depois degrada de boa. Só o `"servico"` recebe
    `key_points` (threaded por `schedule_payload` nos dois tools → `payload[:key_points]` →
    renderer); `"implantacao"` nunca. `#parse_schedule_key_points` valida/ordena/corta em 6.
    Dois caminhos pra popular, os dois SEMPRE em background (mesma regra de reentrância de
    `Conversation#complete` — nunca IA síncrona dentro da tool call), disparados por
    `GenerateProposalDocumentTool#ensure_schedule_background_work!` e
    `InsertScheduleSectionTool#ensure_schedule_background_work!` a cada geração:
    - **Cronograma novo**: `SuggestScheduleJob` → `#build_with_ai_suggested_schedule!` já pede os
      marcos na MESMA chamada que sugere o cronograma inteiro (`schedule_suggestion_prompt` ganhou
      a chave `marcos_infografico`).
    - **Cronograma que já existe** (proposta criada antes desta funcionalidade, ou montado à mão
      na Tela de Precificação — `build_with_ai_suggested_schedule!` só roda quando não há item
      nenhum, então sem isto o infográfico ficava pra sempre no fallback de fase):
      `ElectScheduleKeyPointsJob` → `Proposal#elect_schedule_key_points!` manda o cronograma já
      montado pra IA e pede só os ≤6 pontos principais (`key_points_suggestion_prompt`), nunca
      mexe nos `schedule_items`. Idempotente: só quando `schedule_key_points` está vazio.
    - **Fallback determinístico imediato (`Proposal#default_schedule_key_points`)**: enquanto o
      job assíncrono ainda não concluiu (ou em ambiente local sem worker rodando), o payload usa
      uma seleção determinística de até 6 marcos cronológicos (atividades com `milestone: true`,
      início, fim e fases principais), garantindo que o infográfico **nunca** saia com mais de 6
      círculos mesmo na primeira geração.
    Nos dois casos a mensagem de retorno da ferramenta avisa o consultor pra gerar de novo em instantes.
  - **Fallback — `collapse_to_phases`**: sem `key_points` e sem itens de serviço (ou cronograma
    de implantação), o `initialize` agrupa atividades por `phase_name` único (`group_by(&:phase_name)`,
    evitando fragmentar fases intercaladas); a fase abrange do início da 1ª atividade ao fim da última.
  - Comum aos dois: numeração 01..N, sem data nenhuma (só a duração em dias, `duration_lines`);
    ponto de span 0 (ou fase toda de marcos) mostra "-". A contagem de dias vem da MESMA conta de
    `ScheduleMspdiExporter#item_start`/`#item_finish` (duplicada de propósito — seção 11.1
    "Decisão de design"). Editar os 6 marcos na Tela de Precificação ainda não existe — só a IA
    popula; regenerar a sugestão (apagar os `schedule_items`) atualiza.
- **Anel/ícone/selo em degradê quente→frio** (`GRADIENT_STOPS`) pela posição da fase no
  cronograma — não uma cor fixa por marco. **Ícone por PALAVRA-CHAVE** no nome da fase
  (`ICON_KEYWORDS`, mapa fechado — mobiliza, campo/campanha, desloca, consolida/análise,
  elabora/relatório, revisão/emissão, envio, protocolo, reunião, aprovação); sem match, ícone
  genérico.
- **Quebra em várias imagens** (`MAX_IMAGE_HEIGHT_EMU`, `#call`/`#svgs` devolvem um Result/SVG
  por imagem) continua como rede de segurança — o Word/LibreOffice cortam sem aviso uma imagem
  mais alta que a página — mas com fase-por-círculo praticamente nunca dispara (só com ~18+
  fases). Numeração contínua entre imagens quando dispara.
- **`ProposalDocxFiller`**: `drawing_run_xml` deixou de ter `IMAGE_WIDTH_EMU`/`IMAGE_HEIGHT_EMU`
  fixos (proporção 4:3, só serve pro mapa) — passa a aceitar cx/cy por chamada, já que o
  infográfico varia de altura conforme o número de linhas. `insert_schedule_tables!` ganhou o
  parâmetro `zip` (só pra poder gravar a mídia rasterizada e registrar o relationship, reusando
  `write_image!`/`add_image_relationship!` — extraído de `fill_images!` pra servir os dois
  casos).
- **CI** (`.github/workflows/ci.yml`, jobs `test`/`system-test`) ganhou `librsvg2-bin` no
  `apt-get install`, ao lado do `default-jre-headless` já lá.

**Resumir o cronograma — cliente achou "gigante" (2026-09).** Um cronograma de serviço real
(34-36 atividades, ~11 meses) saía com ~11 páginas: infográfico em 3 imagens paisagem + tabela
com dezenas de colunas de SEMANA. O cliente liberou deixar mensal ("não é obrigatório ficar
semanal"). Duas mudanças, sem flag nova (vale pros dois fluxos — geração normal e
`insert_schedule_section` —, `ScheduleMspdiExporter` não muda, segue semanal por atividade):
- **Infográfico → ≤6 marcos eleitos pela IA** (fallback: um círculo por FASE — ver acima).
- **`ScheduleTableBuilder` → colunas de MÊS CIVIL pro cronograma semanal.** `initialize`: quando
  `unit == :week`, `to_monthly` converte cada item pra intervalo de meses civis a partir de
  `start_date` (`months_between`) e segue com `@unit = :month` — reaproveita o caminho `:month`
  inteiro que já existia (`month_grouping`, consolidação `bucket_size`, rotação). A Tela de
  Precificação e o `ScheduleItem` no banco continuam semanais; a conversão é só de exibição no
  `.docx`. `NAME_COL_WIDTH` subiu de 1632 pra 2800 dxa (com poucas colunas de mês sobra largura,
  e nome de atividade largo o bastante pra não quebrar em 3 linhas encurta a tabela).
- Verificado ao vivo (36 atividades / 8 fases / ~11 meses → LibreOffice → PDF): o bloco caiu de
  ~11 pra 4 páginas paisagem (1 infográfico + 3 tabela), colunas de mês cabendo na largura.

**Rodada de revisão da Papyrus sobre a proposta QAIR (PTC26018, 2026-09) — correções pontuais:**
- **Quadro SUMÁRIO DE REVISÕES saía cortado** pela borda direita da página: tinha `tblW`/`tblGrid`
  de 9912 dxa num corpo de texto de 8504 dxa (margens de 1701 dxa em `w:pgMar`) e era `w:jc
  center` + `tblLayout fixed`, então a coluna "Data" era clipada. Reescaladas as 3 colunas pra
  1253/5450/1791 (soma 8494, igual às outras 3 tabelas do modelo) por substituição de string crua
  no XML; removido também o `<w:ind w:left="-1094"/><w:jc w:val="right"/>` que um re-save do Word
  tinha deixado nas linhas-molde 04–10 (era o desalinhamento visível). Teste em
  `proposal_docx_filler_test.rb` trava que NENHUMA `<w:tbl>` do modelo passe da área útil de texto.
- **"CONTRATADA" → "PAPYRUS" em negrito**: além da troca do texto (feita antes), os runs onde
  "PAPYRUS" aparece agora foram divididos pra a palavra ficar em `<w:b/>` isolada (obrigação 7.1
  sobre relatórios + os 2 usos na seção PRAZO), igual "PAPYRUS" já aparecia nas obrigações 7.2.
- **Linha "Ref.:" concordava errado**: o modelo trazia `nos municípios de {{MUNICIPIOS}}` cravado
  no plural (saía errado com 1 município). Virou `Ref.: {{REF_LINHA}}`, montada em
  `GenerateProposalDocumentTool#build_ref_linha` — "no município de X" / "nos municípios de X e Y"
  conforme a contagem, e "estado da Bahia" / "estado de São Paulo" / "estado do Pará" / "no
  Distrito Federal" via `UF_NOMES`/`UF_ARTIGO`. Os placeholders `{{DESCRICAO_SERVICO}}`/
  `{{MUNICIPIOS}}`/`{{ESTADO}}` saíram do modelo (só existiam nessa linha) mas continuam sendo
  passados (inofensivo).
- **Observações fixas no item de preços** (pedido "deixar fixo"): 5 parágrafos fixos no modelo,
  logo depois do `Quadro 11-1` (Desembolso) e antes de "DADOS BANCÁRIOS" — correção anual
  IGP-M/IPCA, CNAE 74.90-1-99 (com "PAPYRUS" em negrito), LC 116/2003 código 17.01, a lista de
  impostos aplicáveis (tributado em Lauro de Freitas) e a condição de pagamento ("em até 30 dias
  após emissão da Nota Fiscal (NF)", acrescentada em 2026-09). Ficam do lado comercial (depois de
  `FIRST_COMMERCIAL_HEADING`), não saem na técnica-sozinha.
- **Prazo padrão 12 meses pra LP/LI**: `GenerateProposalDocumentTool#prazo_execucao_value` força
  "12 (doze) meses contratuais" quando o(s) achado(s) `tipo_licenca` batem `LP_LI_FAMILY_ACTS`
  (LP/LI/RLP/RLI/LPI) — pedido do consultor ("sempre estabelecer… nestes casos"). Regra
  determinística, sobrepõe o texto da IA; nos demais atos vale o que a IA escreveu.
  `Proposal#license_act_acronyms` virou público pra isso (reusa `#license_acronyms_in`).
- **Equipe sem `study_template`: a IA mapeia a partir do cadastro completo (2026-09, pedido da
  Charlene — "cadastrar um template por tipo de estudo é difícil").** Antes, tipo de estudo sem
  `study_templates` (tudo menos `eia_rima`) fazia `build_with_ai_suggested_team!` sair só com a
  Diretoria/Coordenação. Agora, nesse caso, o "menu" da IA passa a ser `Professional.active` (menos
  os `always_included`, que o sistema junta sozinho) com cargo + especialidades, e ela escolhe
  QUEM entra e o QUE cada um entrega nesta proposta (`roster_suggestion_prompt`/
  `apply_roster_lines!`). Continua restrito a `professional_id` real e ativo (a IA nunca inventa
  gente; id inválido vira achado `sugestao`); o `deliverable_name` é livre (não há catálogo de
  entregável fora do `eia_rima`). `eia_rima` mantém o caminho estrito de sempre (`study_templates`
  + `apply_lines!`) — é um menu curado melhor que mapeamento livre. Falha/JSON inválido cai no
  `rescue` → `build_from_template!` (só Diretoria/Coordenação), igual antes.
- **Quadro EQUIPE TÉCNICA do `.docx` virou dinâmico (2026-09).** Era um esqueleto quase fixo
  (Charlene/Ricardo/Pedro/Molina cravados no XML + 2 vagas de placeholder — `{{EQUIPE_LIDER_*}}` e
  `{{EQUIPE_SEG_TRABALHO_*}}`, preenchidas por `Proposal#team_slot_for_docx`, que devolvia a
  Charlene como "Líder do Projeto" numa proposta sem template). Agora a tabela (índice 2) é
  preenchida por linha, uma por `proposal_professional`, via `Proposal#team_rows_for_docx` →
  `[SETOR, FUNÇÃO, PROFISSIONAL, HABILITAÇÃO/REGISTRO]`. A tabela-molde do modelo foi reduzida a
  cabeçalho + 1 linha em branco (era 7 linhas com `vMerge`), e `team_slot_for_docx`/os 4
  placeholders `{{EQUIPE_*}}` foram removidos.
  - **SETOR derivado** (`Proposal#docx_team_sector`, sem cadastro novo — decisão do consultor):
    Diretoria = `always_included` com "diretor" no cargo; Gestão = os demais `always_included`
    (Coordenação); Execução = todo o resto. Linhas ordenadas por setor e depois por nome. O texto
    do setor **repete por linha** (sem `vMerge` — mais simples, decisão do consultor).
  - **FUNÇÃO** = `proposal_professional.deliverable_name` (o que a pessoa entrega NESTA proposta),
    não o cargo genérico. **HABILITAÇÃO** = `professional.specialties — professional.registration`.
  - Verificado ao vivo (LibreOffice headless → PDF → captura): 5 membros em 3 setores saem todos,
    agrupados, fluindo pra página seguinte quando não cabem. Efeito colateral aceito: quando uma
    linha quebra entre páginas, a célula SETOR da continuação sai vazia (mesmo comportamento da
    tabela antiga).
- **Objetivo/Caracterização vazando pro escopo + parágrafos longos**: reforços só de PROMPT —
  `param :objetivo_dos_servicos`/`:caracterizacao_do_empreendimento` agora dizem o que NÃO entra
  em cada seção, e o `description` da ferramenta pede parágrafos de no máximo ~5 linhas.
- **Órgão sempre genérico no TEXTO da proposta (2026-09, pedido da Charlene):** o `description` da
  ferramenta proíbe escrever o nome/sigla de qualquer órgão (INEMA, IBAMA, FEPAM, CETESB, INEA,
  SEMA, SPRH...) ou de sistema interno (SEI/SEIA/e-Protocolo) no corpo do documento — a IA usa
  "o órgão ambiental", "o órgão ambiental licenciador", "o órgão interveniente". Assim o texto
  serve pra qualquer caso. A identificação do órgão específico continua acontecendo normalmente
  no estudo/achados/CAL (`ProcessEtJob`, mapa estado→órgão, `ProcessLegalNormsJob`) — só não vai
  pro texto entregue ao cliente.
- **Ainda pendente da mesma rodada:** correção de português/concordância no texto gerado (não há
  passo de revisão gramatical hoje — só o reforço de prompt), extração do destinatário ("Prezado
  Sr. X") a partir do e-mail do cliente anexado como complementar, e o achado "capa" / "dados
  bancários" (o consultor pediu pra deixar de fora desta rodada).

**Quadro SUMÁRIO DE REVISÕES: linha duplicada/descrição em branco (2026-09, correção do
consultor).** Duas falhas na tabela de revisões (página 2 do modelo):
1. **Linha duplicada** — `Proposal#docx_revision_rows` montava as linhas PASSADAS a partir de
   `generated_documents.map(&:blob)` sem filtrar contra a versão ATUAL (já incrementada antes da
   chamada, ver comentário do método) — um blob perdido com `metadata[:version]` igual à versão
   corrente (uma tentativa anterior que falhou depois de anexar, ou uma corrida entre gerações)
   produzia duas linhas com o mesmo número de revisão na tabela. Corrigido: `past_rows` agora
   filtra `blob.metadata["version"].to_i < version`.
2. **Descrição em branco ou repetindo "Emissão Inicial"** — quando `descricao_revisao` não vem
   (a IA não recebeu o parâmetro) numa revisão que NÃO é a primeira, a linha saía sem descrição
   nenhuma, ou repetindo "Emissão Inicial" (rótulo que só faz sentido pra revisão 00). A partir da
   2ª revisão (`v.to_i > 1`/`version > 1`), descrição em branco ou igual a "emissão inicial"
   agora vira "Revisão solicitada pelo consultor" — tanto nas linhas passadas quanto na atual. A
   1ª revisão (rev "00") fica de fora dessa troca de propósito: "Emissão Inicial" (em branco ou
   não) é o rótulo implícito dela por convenção, igual `curr_desc` já trata `version <= 1` à
   parte.
   **Achado ao vivo, corrigido nesta sessão:** a refatoração acima passou a chamar um método novo,
   `fill_revisions_table!(table_node, rows)`, no lugar de `fill_table!` pro índice 0 — mas o
   método nunca foi definido em `ProposalDocxFiller`. Toda chamada de `#fill`/`#fill_split` com
   uma tabela de revisões (ou seja, TODA geração normal de proposta) levantava `NoMethodError`
   dentro do `rescue StandardError` de `GenerateProposalDocumentTool#execute` — o erro nunca
   chegava ao consultor como mensagem de erro específica, só "não funcionou" (nenhum `.docx`
   anexado, sem pista do motivo). Corrigido definindo `fill_revisions_table!` como um wrapper fino
   de `fill_table!(tbl, rows_data, auto_number: false)` — a tabela de revisões preenche do mesmo
   jeito de sempre, só nunca com numeração automática (a coluna "N°" já vem pronta de
   `docx_revision_rows`, calculada a partir de `version`, não de posição de linha). Verificado ao
   vivo gerando a proposta 18 de novo (conversa 32, o caso que reportou "não funcionou"): saiu
   `.docx` completo, com a tabela de revisões e o infográfico de ≤6 marcos os dois corretos.

**Duas correções de seguida no mesmo quadro (2026-09, pedido do consultor: "tem que sair com
várias linhas vazias também... deve ficar com 10 linhas por padrão"):**
1. **`fill_revisions_table!` ganhou `trim: false`** — o `fill_table!` genérico sempre APAGA a
   linha de molde que sobra sem dado (comportamento certo pras outras 3 tabelas: equipe/produtos/
   desembolso não têm "linha vazia de reserva"). Mas o modelo da Papyrus já traz o Sumário de
   Revisões pré-numerado "00" a "10" (11 linhas, Descrição/Data em branco) — era esse molde que a
   1ª correção acima passou a apagar sempre que a proposta tinha menos de 11 revisões, sobrando só
   as linhas preenchidas. `trim: false` é um parâmetro novo em `fill_table!` (default `true`,
   inofensivo pras outras tabelas) que faz a linha de molde sobrando ficar como está, em vez de
   remover — cresce normalmente se um dia passar de 10 revisões (`version > 11`), mesma lógica de
   clonagem de sempre.
2. **Achado ao vivo nesta correção, também corrigido: o CABEÇALHO da tabela ("Revisão | Descrição
   da Revisão | Data") vinha sendo apagado silenciosamente em TODA proposta gerada, desde que essa
   funcionalidade existe** — não só nesta sessão. Causa: `fill_table!` assume 1 linha de cabeçalho
   antes da 1ª linha de dado (`all_rows[1]` = molde) — vale pras outras 3 tabelas (rótulos das
   colunas na linha 0, dado na linha 1), mas o Sumário de Revisões tem DUAS linhas antes do dado:
   o título mesclado "SUMÁRIO DE REVISÕES" (linha 0) E só depois os rótulos "Revisão/Descrição da
   Revisão/Data" (linha 1) — a 1ª linha de dado real ("00") só começa na linha 2. `fill_table!`
   pegava a linha de RÓTULOS como se fosse o molde de dado, e a 1ª chamada de preenchimento
   sobrescrevia "Revisão"→"00", "Descrição da Revisão"→"Emissão Inicial" etc. — o cabeçalho da
   coluna nunca aparecia no `.docx` final, só o título "SUMÁRIO DE REVISÕES" sozinho em cima dos
   dados. `fill_table!` ganhou `header_rows:` (default `1`, igual sempre foi pras outras tabelas);
   `fill_revisions_table!` passa `header_rows: 2`.
   Verificado ao vivo (LibreOffice headless → PDF → captura, proposta 18 de novo): o cabeçalho
   "Revisão | Descrição da Revisão | Data" aparece corretamente acima dos dados, e a tabela sai
   com 11 linhas mesmo com só 8 revisões reais — as 3 últimas ("08", "09", "10") em branco.

---

## 9. Prompts do sistema (2 prompts principais)

**Prompt 1 — Sistema (contexto fixo):** dados fixos da Papyrus — razão social, CNPJ, endereço, dados bancários, texto institucional, lista de profissionais (nome, formação, registro, área de atuação), tabela de preços base, marcos de desembolso padrão (ex.: 30% assinatura, 60% protocolo, 5% vistoria, 5% emissão), regras de negócio (quando muda tipo de estudo, o que vira proposta complementar), nomes/cargos dos diretores que assinam. Atualizado manualmente quando necessário — **não deve ir para tabelas de cadastro nesta versão**, fica no prompt.

**Prompt 2 — Geração de Proposta:** instrui a IA sobre como estruturar o conteúdo — quais seções gerar, como organizar os dados, quais campos preencher. Retorna texto estruturado que o backend usa para montar o PDF.

---

## 10. Requisitos não-funcionais

- Processamento do ET/TR: até 120s (documentos até 100 páginas).
- Processamento do KMZ: até 30s.
- Geração do PDF final: até 60s.
- Suporte a até 5 usuários simultâneos (fase inicial).
- TLS 1.3 em trânsito; arquivos armazenados (ET, TR, KMZ, PDFs) criptografados.
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
2. Retomada do módulo geoespacial (KMZ/PostGIS), hoje pausado — **parcial (2026-09): só a
   camada `ibge_municipalities`**. Das 6 camadas de referência listadas na seção 3 (Mata
   Atlântica, UCs, TIs, quilombos, bacias continuam de fora, mesmo status de antes), só município
   foi construído:
   - `db/migrate/..._create_ibge_municipalities.rb` + `app/models/ibge_municipality.rb` —
     `code_ibge` (chave natural, 7 dígitos), `name`, `uf`, `geom` (`geography`, tipo
     `multi_polygon`, SRID 4326 — mesmo tipo de `geospatial_results.geometry`, pra `ST_Intersects`
     entre as duas colunas não precisar de cast). Índice GIST em `geom`.
   - `script/geospatial/import_ibge_municipalities.rb` — popula a tabela a partir das APIs
     públicas do próprio IBGE (uma por UF: malha em `/api/v3/malhas/estados/{cod}` + nomes em
     `/api/v1/localidades/estados/{cod}/municipios`, já que a malha só traz o código `codarea`,
     sem nome). `qualidade=minima` na malha — geometria generalizada, arquivo bem menor; não
     precisa de precisão cartográfica fina pra "em qual município esse KMZ cai". Idempotente
     (upsert por `code_ibge`), roda por UF pra um erro no meio não perder o que já baixou:
     `bin/rails runner script/geospatial/import_ibge_municipalities.rb [--ufs SP,RJ,...]`.
     **Ninguém rodou o import das 27 UFs em produção ainda** — só testado localmente com uma UF
     pequena (SE, 75 municípios) pra validar o pipeline; falta rodar o import completo.
   - `ProcessKmzJob#cross_reference_municipalities!` roda `IbgeMunicipality.intersecting(
     geospatial_result.geometry)` (`ST_Intersects`, não `ST_Contains` — uma linha de transmissão
     pode atravessar a fronteira entre dois municípios sem estar inteiramente contida em nenhum) e
     grava em `geospatial_results.municipalities` (jsonb — coluna que já existia desde 16/07,
     nunca escrita até agora) + um `ProjectFinding` novo (`field: "municipios"`,
     `source_kind: "sistema"`) — **mesmo campo que `ProcessEtJob`/`ProcessTrJob` já usam** pro que
     a IA lê do documento, o que faz o `ProjectFindings::ConflictDetector` comparar de graça o
     que o ET/TR declara com o que a geometria do KMZ realmente mostra, sem nenhum código novo de
     comparação. Nunca bloqueia o job (tabela vazia ou erro na query só deixa `municipalities`
     como `[]`, igual antes).
   - `GeospatialResult#summary_text`/`#municipalities_label` passam a incluir "· Município(s):
     Nome/UF" quando presente — a Tela de Resultado (`conversations/show.html.erb`) não precisou
     de nenhuma mudança própria, ela já reusa `summary_text` no card e no modal de zoom do mapa.
   - **CI** (`.github/workflows/ci.yml`): o serviço `postgres` dos jobs `test`/`system-test`
     trocou de `postgres` (sem PostGIS) pra `postgis/postgis:17-3.5` — sem isso a extensão
     `postgis`/as migrations espaciais nunca eram validadas em CI. **Pendência conhecida, não
     resolvida agora**: esse mesmo serviço também precisa da extensão `vector` (pgvector, seção
     11.1 item 3) pro RAG, e a imagem `postgis/postgis` não traz pgvector — combinar as duas
     extensões numa imagem de serviço do GitHub Actions exige uma imagem própria (build custom,
     `services:` só aceita referência de imagem pronta) e ficou fora do escopo desta mudança.
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
       do ET (e do TR, quando houver) e informa no resumo quais projetos anteriores se parecem com este ("25051 ·
       Petrobras · Diagnóstico Quilombola — referência direta"). É o caso real do consultor:
       mesmo serviço, outra área — a proposta antiga é o melhor ponto de partida, e não adianta
       ela ficar no acervo se ninguém for buscá-la. Cumpre os itens 4 e 9 do passo a passo
       interno.

       **Calibragem (o score bruto de similaridade não serve).** Num acervo de domínio único o
       cosseno entre dois textos quaisquer já parte alto: medido neste acervo, uma receita de
       bolo tira 0,51, uma frase sobre migração de PostgreSQL tira 0,60 e a frase vazia
       "serviços de consultoria ambiental para licenciamento" tira 0,68 — contra o corte de 0,60
       que existia. Numa proposta de BESS para a Rio Energy o sistema anunciou "73% semelhante"
       a um job de execução de PBA, sendo que dois dos três trechos que geraram o número eram a
       CAPA da proposta antiga (que traz o nome do cliente) e o acervo não tem projeto de BESS
       nenhum. Quatro peças corrigem isso:
       1. **Descritor de serviço** (`GenerateSummaryJob::SEARCH_FIELDS`): a consulta é montada
          campo a campo, com orçamento por campo, só com o que descreve o SERVIÇO. Cliente,
          contato, prazo e nome de arquivo ficam de fora — cliente é faceta de filtro, nunca
          semântica. `ProcessEtJob` (e `ProcessTrJob`, quando houver TR) extrai um campo
          `empreendimento` (tecnologia e porte) justamente para alimentar isto.
       2. **`Rag::BoilerplateDetector`**: marca o trecho que aparece em ≥20% dos outros jobs
          (obrigações, validade, prazo, condições de pagamento) — é IDF aplicado a trecho. Fica
          fora da comparação entre jobs, mas continua recuperável na busca direta. Roda no fim
          de `script/rag/index.rb`, ou avulso por `script/rag/boilerplate.rb`; não custa IA.
          O Preâmbulo NÃO é marcado de propósito: ele carrega o "Ref.: Proposta Técnica para
          ...", às vezes a melhor descrição do job.
       3. **`Rag::CorpusFloor`**: o piso é a similaridade da consulta com o CENTROIDE do acervo
          (`avg(embedding)` do pgvector, sem tabela nova). Descontá-lo devolve o que sobra de
          específico. Quando nenhum trecho supera o piso, a consulta está mais perto da média do
          acervo do que de qualquer documento dele.
       4. **Domínio da cabeça do ranking**: quando existe projeto parecido de verdade, ele ocupa
          quase todos os primeiros lugares; quando não existe, a cabeça se espalha. Os cortes
          (`MIN_DOMINANCE`, `MIN_STRENGTH`) foram medidos contra oito consultas de resposta
          conhecida — a tabela está no comentário do `SimilarJobFinder` e deve ser refeita ao
          mudar chunking, modelo de embedding ou acervo.

       Duas consequências de interface: o resumo passa a poder dizer **"nenhum projeto anterior
       semelhante"** (antes o corte garantia três sugestões sempre, então o consultor não
       distinguia achado de coincidência), e **não exibe mais porcentagem** — só "referência
       direta" ou "aproveitável em parte", porque a faixa útil inteira cabe entre 0,68 e 0,75 e
       o número comunicava uma precisão inexistente.

       **Segunda calibragem — precedente MÚLTIPLO (2026-09, achado ao vivo).** O acervo cresceu
       de ~400 pra ~3.000 documentos, e passou a existir mais de um job parecido pra assunto que
       antes tinha só um (BESS: 4 propostas reais no acervo, `26098`/`26095`/`26089`/`26063`).
       `MIN_DOMINANCE` pressupõe UM job só ocupando a cabeça do ranking — com 4 jobs dividindo a
       cabeça, nenhum sozinho passava de ~0,3, e "projetos semelhantes" saía vazio numa proposta
       de BESS de verdade, com força positiva (+0,06 a +0,11) sentada bem ali. Medido de novo com
       o descritor REAL de conversas (não frase solta — o formato da consulta importa) contra o
       acervo atual:
       ```
       consulta (formato real)              domínio(top3)  força do 1º   deve achar?
       conversa 34 (BESS Newave)                  0,7          +0,06     sim — 4 jobs de BESS
       "bolo de fubá" (formato descritor)         0,4          -0,02     não
       "migração de PostgreSQL" (formato descr.)  0,4          -0,11     não
       "consultoria ambiental" vaga (descritor)   0,7          -0,08     não
       ```
       O que separa o positivo dos três negativos não é o domínio combinado (todos entre 0,4 e
       0,7) — é ter pelo menos DOIS jobs distintos com força PRÓPRIA boa (>= piso do acervo, não
       só "não catastrófica"). `Rag::SimilarJobFinder#clustered_match?` — novo caminho somado ao
       estrito de sempre (que continua intacto): job entra sem dominar sozinho a cabeça se tiver
       força própria >= 0 (`CLUSTER_MIN_STRENGTH`) E não estiver isolado (pelo menos
       `CLUSTER_MIN_JOBS` = 2 jobs com dominância >= `CLUSTER_MIN_DOMINANCE` = 0,2). O teste
       "cabeça espalhada entre muitos jobs não produz sugestão nenhuma" (já existia) continua
       batendo — cada job isolado ali nem chega em 0,2 de dominância.

       **Achado junto, não corrigido ainda:** a mesma consulta vaga "consultoria ambiental" ainda
       encontra um job pelo caminho ESTRITO (não o novo) — `MIN_STRENGTH = -0.20` também ficou
       datado com o acervo maior, mas não tenho hoje um caso positivo real o bastante perto desse
       limite pra reapertar sem risco de cortar um precedente bom de verdade junto. Fica registrado
       pra próxima calibragem, quando aparecer mais um caso real (positivo perto do limite, ou um
       falso positivo pego em produção).

       Ainda **não implementado**: ranquear também por facetas determinísticas (mesmo órgão,
       mesmo enquadramento, mesma tecnologia) extraídas dos jobs do acervo, e mostrar esses
       motivos no lugar do rótulo. Depende de uma passada de classificação sobre o acervo
       (1 chamada de IA por job) e de uma coluna nova.
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
   - **Aprender com a versão final revisada manualmente (2026-09).** `IndexApprovedProposalJob`
     só indexa o que passou por `proposals#approve` NESTE sistema — mas às vezes alguém da
     Papyrus (ex.: Charlene) pega o rascunho que a IA gerou, reescreve/ajusta e produz a versão
     que realmente vai pro cliente, sem que isso passe pela aprovação daqui (pode nunca ser
     re-subida como "documento gerado"). Sem um caminho pra essa versão, a IA nunca aprendia com
     o texto que a Papyrus de fato validou como pronto pra enviar.
     - `LearnFromRevisedProposalTool` — o consultor anexa o `.docx` final no chat da própria
       proposta (mesmo mecanismo de documento complementar já existente, sem UI nova) e diz que
       aquela é a versão final; a ferramenta acha o anexo mais recente da conversa (mesmo
       princípio de "só o mais recente conta" de `Message#stale_for_llm?`), extrai o texto
       (`Rag::TextExtractor`) e cria um `HistoricalProposal` com `origin: "revisao_manual"`,
       `role_source: "consultor"`. Idempotente pelo mesmo checksum de sempre
       (`source_sha256: "blob:..."`) — reenviar o mesmo arquivo não duplica o card.
     - **Curadoria não é opcional aqui também** (mesmo princípio do item 4 abaixo,
       `KnowledgeNote`): a ferramenta não indexa na hora — cria o registro com
       `review_status: "pending"` e o texto extraído em `pending_text`, e posta um card no chat
       (mesmo mecanismo de mensagem assistant própria + broadcast já usado pelo card de
       `KnowledgeNote`). Só quando o consultor aprova (`HistoricalProposal#approve!`,
       `HistoricalProposalReviewsController`) o texto é chunkado e embedado de verdade.
     - **Atomicidade por construção, sem filtro em nenhuma busca**: `review_status` default
       `"approved"` pra todo registro já existente (acervo em disco, `IndexApprovedProposalJob`)
       — nada muda pra eles. Só o caminho novo nasce `"pending"`, e um registro pendente
       simplesmente não tem `HistoricalProposalChunk` nenhum ainda — `SimilarJobFinder`/
       `Retriever`/`SearchHistoricalArchiveTool` só enxergam chunks, então um documento pendente
       já é inencontrável por construção, sem precisar ensinar nenhuma dessas três consultas a
       filtrar "pendente". `#approve!` roda tudo (mudar status + chunkar + embedar) numa
       transação só, mesmo padrão de `KnowledgeNote#approve!`: se embedar falhar (chamada
       externa), o registro volta exatamente como estava, pending_text incluso, pra tentar de
       novo — nunca fica "aprovado" sem vetor nenhum.
     - `Rag::ProposalIndexer` — o passo salvar+chunkar+tagear sensibilidade+embedar que antes
       vivia dentro de `IndexApprovedProposalJob` foi extraído pra cá, reaproveitado pelos dois
       chamadores (aprovação de proposta E aprovação deste card) — só o gatilho e os atributos
       de origem mudam entre os dois.

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
   - **Também nasce fora de proposta, no chat geral (seção 14, 2026-09):** `KnowledgeNote` agora
     tem `conversation_id` OU `general_chat_id` (nunca os dois — validado em `belongs_to_exactly_
     one_origin`), porque uma exigência de cliente pode aparecer numa conversa avulsa de dúvidas,
     não só dentro de uma proposta em andamento. `RememberForFutureProposalsTool` ganhou
     `initialize(conversation: nil, general_chat: nil)` e ganha `@owner` = o que veio; como
     `GenerateSummaryJob` busca notas aprovadas por `client_name` direto na tabela (nunca via
     `conversation.knowledge_notes`), uma nota nascida no chat geral já reaparece sozinha numa
     proposta futura do mesmo cliente, sem nenhuma outra mudança. Fora de uma proposta não há
     cliente pra herdar — a ferramenta ganhou um parâmetro `cliente` (opcional, ignorado dentro de
     uma proposta, onde o cliente já é um fato do sistema) pra IA informar quando identificar de
     quem se trata; sem cliente identificável, a nota fica salva mas não amarrada a nenhum (regra
     geral da Papyrus), e só reaparece se for buscada.
   - **Bug achado ao vivo nesta sessão, corrigido:** o card "Guardar"/"Descartar" nunca aparecia
     no chat de verdade. Causa: o retorno da ferramenta vira uma mensagem `role: "tool"`, e
     `Message#hide_tool_result!`/`GeneralMessage#hide_tool_result!` sempre esconde mensagens desse
     role — sem querer, isso também escondia o JSON que alimentava o card (mesmo problema afeta
     `GenerateProposalDocumentTool` e `AddExternalCostTool`, ainda não corrigidos). Corrigido só
     para `RememberForFutureProposalsTool`: ela agora grava uma mensagem PRÓPRIA, direta,
     `role: "assistant"` (`@owner.messages.create!(content: { knowledge_note_id: note.id }.to_json)`),
     mesmo padrão que já funcionava pro card de `ProjectConflict` (`GenerateSummaryJob`, mensagem
     criada fora de qualquer tool call). Isso por si só não bastava: `RespondToMessageJob`/
     `RespondToGeneralChatMessageJob` só faziam `broadcast_append_to` da ÚLTIMA mensagem assistant
     do turno — o card (mais antigo que a resposta em texto da IA) nunca era transmitido ao vivo,
     só aparecia depois de um F5. Os dois jobs agora rastreiam os ids de mensagem de ANTES da
     chamada à IA e fazem broadcast de TODAS as mensagens assistant novas do turno, em ordem
     (`animate` só na última — um card não precisa do efeito de máquina de escrever).

**Decisão de design:** não adotar a arquitetura genérica de "tipos de conhecimento" proposta no estudo — o domínio deste projeto é estreito e já bem modelado (`study_types`, `professionals`, `study_templates`, parâmetros de logística direto em `project_pricings`). Preferir estender essas tabelas concretas conforme a necessidade aparecer, em vez de construir uma camada de abstração genérica antecipadamente.

### 11.2. CAL/Ius Natura — normas legais (implementado)

A Papyrus assina o CAL (`sistemacal.com.br`), base de legislação ambiental da Ius Natura, e
precisa que a IA consiga citar a norma exata por trás de uma exigência ao escrever a proposta
(ex.: qual resolução exige um inventário florestal, qual portaria rege um procedimento do órgão)
em vez de generalizar. O CAL não tem API pública — é uma aplicação ASP.NET MVC clássica (login por
formulário, sessão por cookie, busca via endpoint AJAX interno), então a integração reproduz
exatamente as requisições que o próprio consultor faria navegando (nunca contorna CAPTCHA, MFA ou
qualquer controle de acesso, nunca acessa dado de outra conta — a mesma regra que já vale pra
qualquer scraping autorizado). Qualquer endpoint novo do CAL precisa do mesmo processo de
descoberta manual antes de entrar no código — **nunca chutar uma URL**. Nem sempre é possível
inspecionar via DevTools/Network (não é este app que roda no navegador do consultor); o endpoint
de download do anexo, por exemplo, foi achado lendo o JS que a própria página autenticada carrega
(`GET` num dos `<script src>` do HTML, grep pelo nome da função usada no `onclick` do resultado de
busca) — mesmo princípio (só reproduzir o que o front-end do CAL já faz), outro meio de leitura.

- `app/services/cal/client.rb` — HTTP + cookie jar manual (`Net::HTTP` não mantém sessão nem
  segue redirect sozinho) + extração do `__RequestVerificationToken` (CSRF) da página de login.
  A sessão fica em `Rails.cache` (TTL de 15 min, conservador porque o CAL não documenta o próprio
  tempo de vida) e é relogada sozinha quando uma chamada volta redirecionada pro login — o
  chamador nunca lida com login/expiração diretamente. `#download` é à parte de `#get`/`#post_form`:
  o CAL redireciona pra uma URL assinada num CDN externo (`files.sistemacal.com.br`, com
  `Expires`/`Signature` próprios), que não leva cookie nenhum — a autorização já está na própria
  URL.
- `app/services/cal/normas.rb` — busca (`POST /NormaLegalBdCliente/Search`), parâmetros e headers
  (`X-Requested-With`, `TabId`) copiados de uma requisição real; `Accept-Encoding: identity` é
  proposital (o CAL comprime com brotli/zstd por padrão, e `Net::HTTP` não descomprime sozinho).
  `#find_by_codigo` reusa a mesma busca com o filtro `NormaLegalCodigos` em vez de `PalavraChave`.
- `app/services/cal/norma.rb` — normaliza uma linha de `colecaoBdCliente` num `Data.define`,
  incluindo o parse da data no formato ASP.NET AJAX clássico (`/Date(ms desde epoch)/`, não
  ISO 8601) e uma `referencia` pronta pra citação.
- `app/services/cal/documento.rb` — a busca só devolve metadados e um resumo curto (`Assunto`); pra
  saber o que uma norma exige de verdade, baixa o PDF real (`GET /UploadArquivo/ObterPdfPorNome
  ?nome=<anexo_id>` → segue o redirect assinado) e extrai o texto com `Rag::TextExtractor` (mesmo
  extrator do RAG do acervo — trata PDF nativo e devolve `nil` num PDF escaneado, em vez de
  inventar/fingir que leu).
- `SearchLegalNormsTool` — mesma filosofia de citação do `SearchHistoricalArchiveTool` (campo
  `referencia` obrigatório no texto), só registrada quando `Cal::Client.configured?`, pra IA não
  "descobrir" uma ferramenta que sempre falharia sem credenciais. Não decide tipo de
  licença/estudo — só fundamenta referência legal do que os achados desta conversa já
  identificaram. Duas formas de uso: `palavra_chave` busca e devolve uma lista com resumo de cada
  norma; `codigo_norma` (o código de uma norma já encontrada numa busca anterior na mesma
  conversa) devolve o texto completo do documento, via `Cal::Documento`. `normas`/`documento` são
  lazy no construtor — `Cal::Client.new` levanta `AuthenticationError` já na criação se faltar
  credencial, e instanciar isso ansiosamente faria a ferramenta quebrar ao ser criada, não ao ser
  chamada.
- **Uso proativo, não só sob demanda** (`app/jobs/process_legal_norms_job.rb`): roda sozinho entre
  o ET e o TR (ver seção 6) — pega o(s) município(s) que o ET identificou, registra
  `SearchLegalNormsTool` e deixa a IA se autogerenciar: decidir o âmbito certo (mais de um
  município → estadual/federal; um único município → qualquer âmbito que se aplique de fato),
  pesquisar quantas vezes precisar, ler o texto completo antes de concluir o que uma norma exige,
  e devolver achados no mesmo formato de `ProjectFindings::Recorder` (`source_kind: "cal"`, campo
  geralmente `"condicionantes"`). Testado ao vivo com um caso real (parque eólico na Bahia): a IA
  sozinha encontrou a Resolução CEPRAM 4636/18 — específica pra eólicas no estado, nunca mencionada
  no prompt — leu o texto completo e extraiu 7 achados corretos, cada um com artigo/trecho literal.
  Pula (`cal: skipped`) quando não há município identificado ou o CAL não está configurado; a
  ferramenta continua disponível sob demanda no chat normal também, registrada pelo mesmo
  `RespondToMessageJob` de sempre.
- **`Conversation#ask_internally` registra a ferramenta sozinho quando o histórico já tem tool
  use** (`messages.exists?(role: "tool")`) — achado ao vivo: assim que `ProcessLegalNormsJob` usa
  a ferramenta uma vez, o histórico passa a ter blocos `toolUse`/`toolResult`, e o Bedrock recusa
  reenviar esse histórico numa chamada seguinte que não declare `toolConfig` (erro "The toolConfig
  field must be defined...", mesmo sem nenhuma tool call nova) — quebrou `GenerateSummaryJob` de
  verdade. Não registra incondicionalmente (abriria a ferramenta pra chamadas que esperam JSON
  puro de volta, tipo `ProcessEtJob`, mesmo em conversas que nunca usaram tool nenhuma) — só
  quando já existe uso anterior nesta conversa.
- Credenciais em `CAL_EMAIL`/`CAL_PASSWORD` no `.env` (mesmo padrão de segredo do projeto — nunca
  hardcoded), carregadas também em teste pelo `dotenv-rails`. Por isso os testes que dependem de
  `Cal::Client.configured?` controlam essas variáveis explicitamente (`CalStubHelper`, em
  `test/test_helpers/cal_stub_helper.rb`, incluído globalmente no `test_helper.rb`) em vez de
  depender do que estiver no `.env` de quem roda.

**`AiJsonResponse` agora tolera texto antes da cerca ```json`` (2026-09):** só removia a cerca
quando ela estava na âncora do início ABSOLUTO da string — funcionava nos jobs de extração normais
(a IA responde só o JSON), mas depois de usar uma ferramenta algumas vezes a IA tende a narrar um
resumo antes ("Com base na pesquisa, identifiquei..."), mesmo o prompt pedindo pra não fazer isso.
Um achado real (7 itens, texto de norma incluído) se perdeu em silêncio por causa disso antes da
correção. Agora busca a cerca em qualquer posição da string e, sem cerca nenhuma, cai para o
primeiro `{` até o **último** `}` (guloso, não `.*?`) — precisa ser guloso porque o JSON tem objetos
aninhados (`achados` é um array de hashes) e um regex não-guloso pararia no primeiro `}` interno.

**Ainda não implementado:** paginação automática (`cal.normas.search_all`, hoje só a 1ª página).

**Legislação do CAL persistida e vetorizada (2026-09, pedido do consultor a partir da conversa
38 — "guardar a legislação pra não precisar processar de novo, e usar o vector pra estudar e
aplicar").** Antes, `Cal::Documento#texto` baixava o PDF do anexo e extraía o texto
(`Rag::TextExtractor`, `ocr: false`) só pra responder a `SearchLegalNormsTool` na hora — nem o
PDF nem o texto ficavam salvos, então a mesma norma era rebaixada e reprocessada do zero a cada
consulta, em qualquer proposta, e PDF escaneado nunca era lido (achado ao vivo na conversa 38:
quase toda norma que a IA tentou ler de verdade veio "não consegui ler o texto do documento").
Agora reaproveita a MESMA infraestrutura de RAG já usada pro acervo histórico de propostas
(`HistoricalProposal`/`Rag::Embedder`/`Rag::SectionChunker`) — legislação vira mais um corpus
vetorizado, não um mecanismo novo.

- **`LegalNorm`/`LegalNormChunk`** (novos) — `LegalNorm` guarda os metadados da norma (mesmos
  campos de `Cal::Norma`), o PDF baixado (`has_one_attached :pdf`) e o texto extraído inteiro
  (`full_text`); `codigo` é a MESMA chave que `SearchLegalNormsTool` já expõe à IA como
  `codigo_norma`, não um id novo. `LegalNormChunk` é o trecho recuperável com vetor
  (`has_neighbors :embedding`, mesmo mecanismo de `HistoricalProposalChunk`) — sem os flags de
  sensibilidade/preço/boilerplate de lá, porque legislação é pública, sem dado de cliente pra
  proteger. **Sem curadoria antes de virar consultável** (diferente de `KnowledgeNote`, que nasce
  `pending`): o texto aqui é legislação oficial baixada direto da fonte, não a IA "achando" algo
  numa conversa — mesmo raciocínio que já vale pra `HistoricalProposal`/`Rag::ProposalIndexer`.
- **`Rag::LegalNormIndexer`** (novo) — mesma receita de `Rag::ProposalIndexer` (salva, chunka via
  `Rag::SectionChunker`, embeda via `Rag::Embedder`), mas paralela: `ProposalIndexer` é hardcoded
  pra `HistoricalProposalChunk`/`historical_proposal_id` e roda no pipeline sensível de aprovação
  do acervo — generalizar essa classe pra servir os dois models trocaria simplicidade por
  indireção nos dois lados. O que É genérico (`SectionChunker`, `Embedder`) continua
  compartilhado; só a cola de persistência (~20 linhas) é duplicada.
- **`Cal::Documento` ganhou `#fetch(anexo_id)`** — baixa + extrai UMA vez, devolve um `Result`
  com `pdf_bytes`/`content_type`/`text`/`ocr_used`. `#texto(anexo_id)` virou `fetch(anexo_id)&.text`
  — mesmo contrato de sempre (String ou nil), nenhum teste existente mudou. **OCR ligado**
  (`ocr: true`, era `false`) — `Rag::Ocr` já cacheia por SHA256 do arquivo em disco
  (`tmp/rag_ocr_cache`), então ligar não tem custo extra pra quem já paga o OCR de outro lugar.
- **`SearchLegalNormsTool#full_text` — cache-first, transparente pra IA.** O contrato da
  ferramenta pra IA não muda (mesmo JSON `{referencia:, texto:, instrucao:}` ou aviso de "não
  consegui ler"). Por dentro: `LegalNorm.find_by(codigo:)` primeiro — se achou, responde sem
  NENHUMA chamada ao CAL (nem busca, nem download); só busca+baixa de verdade na 1ª vez que
  aquele código é pedido em QUALQUER conversa (legislação de licenciamento na Bahia se repete
  bastante entre propostas diferentes). Quando o texto vem vazio (sem anexo, ou ilegível mesmo com
  OCR), não persiste nada — o cache de OCR por SHA256 já evita repetir o custo caro de qualquer
  forma. Verificado ao vivo: 1ª chamada pra uma norma nova levou 6,25s (busca + download + OCR +
  embedding); 2ª chamada pro MESMO código, 0,0s (zero tráfego de rede).
- **`SearchLegalNormsArchiveTool`** (nova ferramenta) — espelha `SearchHistoricalArchiveTool`:
  busca semântica só no que JÁ foi guardado (`LegalNormChunk.embedded`), sem tocar o CAL, mais
  rápido, sem rede. Registrada nos mesmos 3 pontos de `SearchLegalNormsTool`
  (`RespondToMessageJob`, `RespondToGeneralChatMessageJob`, `ProcessLegalNormsJob`), com o mesmo
  gate condicional de `SearchHistoricalArchiveTool` (`LegalNormChunk.embedded.exists?` — só
  oferece a ferramenta quando há algo pra achar). `ProcessLegalNormsJob` (pesquisa proativa entre
  ET e TR) passou a instruir a IA a checar esta ferramenta primeiro, antes de ir ao CAL com
  `search_legal_norms`. Não substitui a busca no CAL — cobre só um subconjunto (o que já foi lido
  antes, de qualquer proposta), então achar nada aqui não significa que a norma não existe.
  Verificado ao vivo com 5 normas reais já guardadas: busca por "documentos exigidos para
  supressão de vegetação nativa" devolveu as normas certas (`NL7484`/`NL17238`/`NL12588`, mesmas
  citadas na conversa 38), com similaridade e referência corretas.
- **Fora de escopo, deliberadamente:** backfill dos códigos já buscados em conversas antigas (só
  passa a cachear daqui pra frente); persistir uma linha "tentei e não consegui ler" pra normas
  sem texto extraível (o cache de OCR por SHA256 já cobre a parte cara).

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
- Anexos de conversa (ET, TR, KMZ, complementares) são Active Storage nativo (`has_many_attached :attachments` em `Message`), não uma tabela `attachments` própria.
- RAG do acervo (seção 11.1): rodar `script/rag/report.rb` e revisar o HTML ANTES de
  `script/rag/index.rb` — indexar é a única etapa que custa dinheiro. A ingestão é idempotente
  por SHA256 + `Rag::Indexer::PIPELINE_VERSION`; suba a versão ao mudar extração ou chunking de
  forma que altere os trechos, senão o que já está indexado não é refeito.
- Limiar de similaridade nunca sai de intuição — é medido. O acervo é de domínio único, então o
  cosseno cru quase não discrimina (ver seção 11.1, "Calibragem"). Ao mexer em recuperação,
  rodar as consultas de controle da tabela em `Rag::SimilarJobFinder`: quatro que devem achar um
  job específico e quatro que não devem achar nada — inclusive uma fora do domínio e uma frase
  genérica do próprio domínio, que é a que engana.
- Achados e divergências (seção 13): informação sobre o projeto só entra no sistema como
  `ProjectFinding`, com origem e natureza — nunca como JSON solto numa mensagem do assistente para
  ser reparseado depois. Ao acrescentar um campo novo, acrescentá-lo ao menu `ProjectFinding::
  FIELDS`, decidindo se ele é `comparable:` (entra na detecção de divergência) — lista acumulativa
  nunca é. Decisão do consultor sobre divergência é sempre um achado novo, nunca um update no que
  o documento disse.
- Stay22 (hospedagem, ver seção 5): chave de API pendente — configurar em `.env`/`ANTHROPIC`-style (`STAY22_API_KEY`) ou `Rails.application.credentials`, nunca hardcoded. Enquanto a chave não estiver configurada, a integração fica com o job/estrutura prontos mas sem chamada real, mesmo padrão usado para Anthropic/Mapbox.
- CAL/Ius Natura (normas legais, ver seção 11.2): credenciais em `CAL_EMAIL`/`CAL_PASSWORD` no `.env`, nunca hardcoded — não é chave de API, é login real (usuário/senha) da conta que a Papyrus assina. `Cal::Client.configured?` decide se a ferramenta é registrada, mesmo padrão de "sem credencial, sem ferramenta" do Stay22.

---

## 13. Achados, evidência e divergências (base da arquitetura agêntica)

A Papyrus trouxe um documento de arquitetura ("Inteligência Agêntica", 30 seções) propondo evoluir
o sistema de IA+RAG para um agente que investiga, cruza fontes, critica as próprias conclusões e
mantém rastreabilidade. **Implementada até agora a fundação** — seções 7, 8, 9, 13 e 16 daquele
documento. O resto (crítica automática, investigação iterativa, aprendizado com correções, banco
como fonte consultável) fica para depois, e depende desta base existir.

### O problema que isso resolve

O entendimento do projeto não existia como dado: era JSON solto dentro de mensagens do assistente,
reparseado a cada uso. Servia para montar um resumo, mas não respondia "por que você concluiu
isso?", e não havia como comparar o que dois documentos dizem sobre a mesma coisa.

### `project_findings` — informação com origem

Cada informação extraída do ET, do TR ou de um complementar vira uma linha: `field` (menu fechado em
`ProjectFinding::FIELDS`), `value`, `nature` (`fato` | `inferencia` | `sugestao`), `source_kind`
(`consultor` > `sistema` > `tr` > `et` > `complementar`, nessa ordem de autoridade — TR vence ET
porque vem da própria instituição/órgão ambiental, autoridade sobre os próprios requisitos), o
blob do documento de origem, o `excerpt` (trecho literal, teto de 300 caracteres) e o `locator`.

- A extração (`ProcessEtJob`, `ProcessTrJob`, `ProcessCompDocsJob`) pede uma **lista de achados**
  em vez de um hash de campos, e grava via `ProjectFindings::Recorder`. Continua **uma chamada de
  IA por documento** — mudou o formato, não a quantidade.
- Campo fora do menu vira `outro` (com o rótulo preservado no valor), nunca chave nova. Natureza
  ilegível vira `inferencia`, nunca `fato`: na dúvida, tratar como dedução é o erro barato.
- `ProcessKmzJob` grava área e perímetro medidos como achados `source_kind: "sistema"`, sem IA.
- Quem consome: `ProcessEtJob#assign_study_type!` (e `ProcessTrJob#assign_study_type!` como
  reforço, quando o ET não tiver definido), `GenerateSummaryJob` (resumo e descritor de serviço do
  RAG) e o snapshot que a IA lê a cada turno.

### Citação inline (`[F12]`)

Cada achado tem um código (`ProjectFinding#citation_code`). A IA recebe a lista no bloco
`[ACHADOS DESTA PROPOSTA]` do snapshot (sem o trecho — ele custaria contexto a cada turno) e cita o
código ao afirmar algo. `ApplicationHelper#render_markdown` troca o código por um chip que abre o
trecho e o documento de origem, **depois** do sanitize. **Código sem achado correspondente é
removido do texto**: marca inventada renderizada como fonte é pior que nenhuma fonte.

**Só existe no CHAT — nunca pode ir pro `.docx` (2026-09, achado ao vivo em produção):** o chip
é coisa de `render_markdown`, que só roda na conversa; `GenerateProposalDocumentTool` não passa
o texto da IA por nenhum tratamento parecido antes de escrever no documento. Uma proposta real
saiu pro cliente com "mediante elaboração de [F681] Estudo Ambiental..." cru no meio da frase —
a IA reaproveitou o hábito de citar achados também nos parâmetros de texto da ferramenta de
geração. Duas camadas de correção: a `description` da ferramenta agora proíbe explicitamente o
formato `[F12]` em qualquer parâmetro (pede citação por extenso, tipo "conforme informado no
ET", quando fizer sentido); e `GenerateProposalDocumentTool#execute` passa todo `args` (strings e
arrays, ex.: `topicos_escopo`/`produtos`) por `strip_citation_codes` antes de usar — rede de
segurança que roda mesmo se a IA ignorar a instrução, reaproveitando `Message::CITATION_PATTERN`
só pra apagar, nunca pra virar link.

### `project_conflicts` — divergência entre documentos

`ProjectFindings::ConflictDetector` roda no `GenerateSummaryJob` (único ponto depois de ET, TR, KMZ e
complementares terminarem). A ordem das etapas é o que segura custo e precisão: só campo
comparável, só entre fontes diferentes, igualdade textual e comparação numérica (tolerância de 2%)
resolvem sem IA, e só o que sobra vai numa **única** chamada em lote para julgar se a diferença é
de grafia ou de conteúdo. Veredito ilegível conta como equivalente.

Divergência **sinaliza, não bloqueia**: vira card no chat, entra no resumo e no bloco
`[DIVERGÊNCIAS ABERTAS]` do snapshot, com a instrução de escrever ressalva em vez de escolher um
lado. Resolver (`ProjectConflictsController#resolve`) **cria um achado novo** com
`source_kind: "consultor"` e marca os divergentes como `superseded` — a decisão humana vira dado,
e o rastro da divergência não se perde.

### Sugestão fora do cadastro

`Proposal#apply_lines!` continua descartando linha de equipe que não existe em `study_templates`,
mas agora registra um achado `sugestao` dizendo o que foi descartado — ou falta cadastro, ou a IA
inventou, e as duas coisas são informação para o consultor.

**O mesmo vale para o tipo de estudo (2026-09, achado na conversa 31, em produção).** A IA
respondeu `"eai"` (Estudo Ambiental Intermediário) num ET real; a Papyrus nunca cadastrou esse
tipo, o `find_by(code:)` não achou nada e `study_type` ficou `nil` **em silêncio**. A partir daí
`GenerateProposalDocumentTool` recusou gerar a proposta para sempre, com uma mensagem que juntava
duas causas e apontava para uma terceira já resolvida ("ET ainda em processamento", com o ET
`done` havia 15 minutos) — a IA concluiu que era falha de backend, repetiu a chamada quatro vezes e
mandou o consultor procurar o time de desenvolvimento. Quatro correções, uma por camada:
- `StudyType.match_ai_value` tolera a IA devolver o NOME no lugar do código (`"EIA-RIMA"` →
  `eia_rima`) — isso é ruído de formato, o sistema resolve sozinho. O que não casa é falta de
  cadastro e precisa de gente.
- `Conversation#assign_study_type_from_findings!` (uma cópia só, era duplicado em `ProcessEtJob`/
  `ProcessTrJob`) registra um achado `sugestao`/`sistema` quando nada casa, mesma regra do
  `flag_out_of_catalog` acima. Não duplica quando ET e TR passam os dois.
- O snapshot que a IA lê a cada turno ganhou o bloco `[BLOQUEIO: TIPO DE ESTUDO]`
  (`Conversation#study_type_blocker_text`), dizendo que o processamento já terminou, o que ela
  identificou, quais tipos existem, e para **não** chamar a ferramenta — e sim mandar o consultor
  escolher na tela. Erro de ferramenta sozinho não basta: ele não diz ONDE se resolve.
- Na tela, o `collection_select` sem `include_blank` mostrava o primeiro tipo da lista como se
  estivesse selecionado — o consultor olhava o painel e via um tipo definido. Agora tem
  "Não identificado", moldura de aviso, e o botão "Avançar para Precificação" desabilitado diz
  por quê.

---

## 14. Chat geral de dúvidas (`GeneralChat`, implementado)

Chat de perguntas e respostas **não amarrado a nenhuma proposta** — o consultor tira uma dúvida de
licenciamento/legislação/prática da Papyrus a qualquer momento, sem precisar abrir (ou ter) uma
proposta em andamento. A IA consulta as mesmas duas fontes de embasamento do chat de proposta —
acervo histórico (`SearchHistoricalArchiveTool`, seção 11.1) e CAL (`SearchLegalNormsTool`, seção
11.2) — e cita a origem, mesma disciplina de sempre. Acessível pelo item "Tira-Dúvidas" na barra
lateral/dock, ao lado de "Propostas".

**Por que é um trio de tabelas à parte (`general_chats`/`general_messages`/`general_tool_calls`),
não uma reaproveitando `Conversation`:** a gem `ruby_llm` (`acts_as_chat`/`acts_as_message`) amarra
`messages.conversation_id` e `tool_calls.message_id` como chave estrangeira literal — não
polimórfica — a uma classe de chat/mensagem específica. Não dá pra um `GeneralChat` sem proposta
conviver na mesma tabela `messages` que `Conversation` sem um `conversation_id` fantasma. Gerado
com `bin/rails generate ruby_llm:install chat:GeneralChat message:GeneralMessage
tool_call:GeneralToolCall model:Model --skip-active-storage` — `model:Model` reaproveita o catálogo
de modelos LLM existente (`models`, sem FK pra chat nenhum, genuinamente compartilhável).
`GeneralChat` declara `acts_as_chat messages: :messages, message_class: "GeneralMessage"` (não
`messages: :general_messages`) só pra manter a mesma interface pública de `Conversation`
(`general_chat.messages`, não `.general_messages`) — `acts_as_model` por sua vez só aceita UMA
associação `chats:`, então `Model` mantém a original (`chats: :conversations`) e ganha
`has_many :general_chats` à parte.

**Cuidado ao rodar o gerador da gem de novo:** ele sobrescreve incondicionalmente
`config/initializers/ruby_llm.rb` (config real do Bedrock) e o `app/models/<qualquer classe já
mapeada, ex.: Model>.rb` existentes com o template genérico — aconteceu ao gerar este trio.
Sempre conferir `git diff` nesses dois arquivos depois de rodar `ruby_llm:install` e restaurar o
que for customização do projeto.

Sem tela de setup: `GeneralChatsController#create` não recebe parâmetro nenhum, só cria o chat pro
usuário atual, aplica `GeneralChat::SYSTEM_INSTRUCTIONS` (prompt próprio — sem proposta, sem ET/TR/
KMZ, sem achados, sem motor de preço) e manda pra tela de conversa. O título da listagem
(`GeneralChat#display_title`) vem da primeira mensagem do consultor, truncada — só é gravado depois
que a IA responde (`RespondToGeneralChatMessageJob`), pra não persistir um título de mensagem que
falhou antes de qualquer resposta.

`RespondToGeneralChatMessageJob` é a versão enxuta de `RespondToMessageJob`: registra só
`SearchHistoricalArchiveTool` (quando há acervo indexado) e `SearchLegalNormsTool` (quando o CAL
está configurado) e `RememberForFutureProposalsTool` (ver seção 11.1, item 4 — algo dito aqui pode
valer pra propostas futuras, mesma memória por cliente de sempre) — nunca `GenerateProposalDocumentTool`
nem `AddExternalCostTool`, que não fazem sentido sem proposta.

**Anexar um documento avulso e tirar dúvida sobre ele (2026-09):** o composer deste chat aceita
upload de PDF/DOCX (`documents[]`, mesmo campo de arquivo do chat de proposta), anexado à mensagem
com `metadata: { kind: "document" }`. É um documento qualquer, sem vínculo com proposta nenhuma do
sistema — a IA lê o conteúdo nativamente (`ruby_llm`) e, quando fizer sentido, cruza com o acervo
histórico (`search_historical_archive`) pra dizer se a Papyrus já tratou de algo parecido, citando
o projeto de referência. `GeneralMessage` ganhou `has_many_attached :attachments` e o mesmo filtro
de "só a mensagem de usuário mais recente reenvia o anexo bruto pra IA" que `Message` já tinha
(`attachment_sources`/`stale_for_llm?`) — sem isso, um documento anexado seria reenviado em toda
chamada seguinte da conversa até estourar o limite de 5 documentos por request da Anthropic. Sem
sidebar de documentos aqui (diferente de `conversations/show.html.erb`) — o anexo aparece como um
chip de download dentro da própria bolha da mensagem (`general_chats/_message.html.erb`).

**Guardar aprendizado pra propostas futuras (2026-09):** o consultor pode dizer, sem nenhuma
proposta aberta, algo que vale a pena lembrar ("a Petrobras sempre exige ART em anexo") — a IA usa
`remember_for_future_proposals` igual faria dentro de uma proposta, e o card de aprovação
(`knowledge_notes/_note.html.erb`) aparece direto na bolha da mensagem, com rota própria
(`GeneralChatKnowledgeNotesController`, `approve_general_chat_knowledge_note_path`). Ver seção
11.1, item 4, pro detalhe de como `KnowledgeNote` passou a nascer de um `GeneralChat` também.
