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
- `messages` — `acts_as_message`; colunas nativas da gem: conversation_id, role, content, content_raw, tokens de entrada/saída/cache. Anexos (ET, TR, KMZ, complementares) via Active Storage nativo (`has_many_attached :attachments`), **não** uma tabela `attachments` própria — o upload na Tela de Setup é a primeira mensagem do usuário na conversa, já com os arquivos anexados
- `tool_calls` / `models` — tabelas nativas da gem (function-calling e registro de modelos LLM com pricing/capabilities); não fazem parte do domínio, mas ficam disponíveis para uso futuro (ex.: extração estruturada de dados do ET)

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

**Revisão do modelo (2026-08, a partir do PTC26002_PMM_Rev01 trazido pela Papyrus):** a seção 10
deixou de ter o quadro de preço aberto por profissional/entregável — o valor que o cliente lê é o
total, escrito na frase de abertura (`{{PRECO_TOTAL}}`), e o único quadro é o de desembolso, agora
com **N° | MARCO | R$ | DATA**. A data de cada parcela é digitada pelo consultor na Tela de
Precificação e mora dentro do próprio `payment_schedule` (jsonb), junto do marco e do percentual;
parcela sem data sai em branco no documento. Também nesta revisão: o quadro de produtos perdeu a
coluna QUANT., a seção 9 (prazo) ganhou um segundo parágrafo, e as obrigações da CONTRATANTE
perderam os itens de rádio comunicador e espaço físico/CATFA. O cálculo continua auditável linha a
linha na Tela de Precificação — o que mudou é o que vai impresso para o cliente.

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

**Cronograma (Gantt) em página paisagem, 2 tipos (2026-09):** toda proposta pode ter um
cronograma visual no `.docx`, baseado num exemplo real da Papyrus (`Quadro 9-1`, tabela nativa do
Word com colunas de período agrupadas e barras coloridas por atividade). Dois tipos, sempre
independentes:
1. **Cronograma do Serviço** (`schedule_type: "servico"`) — as atividades do próprio
   estudo/licenciamento (reuniões, campo, protocolos, emissão da licença). Em **semanas**.
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
  EXECUÇÃO" é sempre a 9ª seção de nível 1 do modelo (estrutura fixa, mesmo princípio de
  `SECAO_ESCOPO_NUMERO`), por isso o número do quadro (`Quadro 9-1`/`Quadro 9-2`) é calculado no
  backend, nunca pela IA.
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

**Exportação em MSPDI pro MS Project (2026-09):** todo cronograma presente também sai como um
arquivo `.xml` à parte, no formato **MSPDI** (o XML de intercâmbio do MS Project — Arquivo > Abrir
importa como projeto completo: fases, atividades, datas, marcos). **Não é o binário `.mpp` de
verdade** — gravar esse formato não é viável em nenhuma linguagem fora de produtos pagos .NET/Java
(a Microsoft nunca documentou escrita, só engenharia reversa parcial pra leitura); MSPDI é o
caminho padrão de qualquer integração séria.
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
VISUAL — círculo numerado + ícone + linha conectando + título e duração em dias por atividade
(sem data — pedido do consultor, 2026-09; marco mostra "-" no lugar da duração), pedido pelo
consultor com uma referência de uma proposta real da Papyrus. Os dois convivem no documento
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
- **Um círculo por ATIVIDADE**, não por fase — a fase não vira círculo próprio, igual a
  referência trazida. Numeração sequencial (01, 02...) por TODO o cronograma, não reinicia por
  linha nem por página. Não mostra data nenhuma (só a duração em dias, `duration_lines`), mas a
  contagem de dias vem da MESMA conta de `ScheduleMspdiExporter#item_start`/`#item_finish`
  (duplicada de propósito — mesmo princípio de não abstrair cedo demais, seção 11.1 "Decisão de
  design").
- **Ícone por PALAVRA-CHAVE** no título da atividade (`ICON_KEYWORDS`, mapa fechado — mobiliza,
  campo/campanha, desloca, consolida/análise, elabora/relatório, revisão/emissão, envio,
  protocolo, reunião, aprovação) — nunca a IA decidindo; sem match nenhum, ícone genérico neutro
  de reserva. Marco (`milestone: true`) usa a cor de destaque (`MILESTONE_FILL`, `C65911` — mesma
  do `Quadro 9-1`) em vez da cor padrão do círculo (`CIRCLE_FILL`, `2E75B6` — mesma paleta da
  tabela, consistência visual com o que já sai na mesma página em vez de inventar cor nova).
- **Achado ao vivo, corrigido (proposta 21, 34 itens/6 linhas de círculos):** uma imagem SÓ com
  todas as linhas ficava mais alta que uma página paisagem inteira, e o Word/LibreOffice
  simplesmente CORTAVA as linhas de baixo — sem erro, sem aviso, as duas últimas fases do
  cronograma real sumiam do documento por completo. Corrigido: `#call`/`#svgs` devolvem um
  Result/SVG **por IMAGEM**, não um só — cronograma que não cabe numa imagem só
  (`MAX_IMAGE_HEIGHT_EMU`, ~5,25pol, com folga pro cabeçalho da página) vira VÁRIAS imagens, cada
  uma seu próprio parágrafo no `.docx` (`ProposalDocxFiller#schedule_timeline_xml`) — Word/
  LibreOffice flui cada imagem que sozinha cabe numa página pra próxima página sozinho, sem
  precisar de quebra de página manual nenhuma. Numeração continua contínua entre as imagens (a
  segunda imagem começa em "19", não reinicia em "01").
- **`ProposalDocxFiller`**: `drawing_run_xml` deixou de ter `IMAGE_WIDTH_EMU`/`IMAGE_HEIGHT_EMU`
  fixos (proporção 4:3, só serve pro mapa) — passa a aceitar cx/cy por chamada, já que o
  infográfico varia de altura conforme o número de linhas. `insert_schedule_tables!` ganhou o
  parâmetro `zip` (só pra poder gravar a mídia rasterizada e registrar o relationship, reusando
  `write_image!`/`add_image_relationship!` — extraído de `fill_images!` pra servir os dois
  casos).
- Verificado ao vivo (mesma metodologia de sempre: gerar proposta real via
  `GenerateProposalDocumentTool`, converter com LibreOffice headless → PDF → captura de tela) —
  confirmado com um cronograma pequeno (8 itens, 2 linhas) E um grande de verdade (34 itens, 6
  linhas, proposta 21): as duas imagens saem completas, legíveis, com a numeração contínua batendo
  (01-18 na primeira imagem, 19-34 na segunda), fluindo pra página seguinte sozinhas, e a tabela
  `Quadro 9-1` continua saindo certa logo depois.
- **CI** (`.github/workflows/ci.yml`, jobs `test`/`system-test`) ganhou `librsvg2-bin` no
  `apt-get install`, ao lado do `default-jre-headless` já lá.

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
