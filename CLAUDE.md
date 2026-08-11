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
| Geração de PDF | Grover (Chrome headless) renderizando templates HTML/CSS no padrão Papyrus |
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

**Proposta e precificação:**
- `proposals` — conversation_id, content_json, pdf_url, version, status
- `project_pricings` — proposal_id, bdi, tax_multiplier, distance_km, total_value, payment_schedule (jsonb)
- `proposal_professionals` — project_pricing_id, professional_id, hours_office, hours_field, subtotal

**Configuração (admin, não muda por proposta):**
- `professionals` — name, role, rate_office, rate_field, registration, specialties, active
- `study_types` — name, code, description (EIA-RIMA, EMI, Relatório Técnico, PEA, RAP...)
- `study_templates` — study_type_id, professional_id, deliverable_name, hours_office_default, hours_field_default (horas padrão copiadas para `proposal_professionals` no início; a taxa vem sempre atualizada de `professionals`)

**Geoespacial:**
- `geospatial_results` — conversation_id, area_ha, perimeter_km, municipalities (jsonb), mata_atlantica (bool), unidade_conservacao (bool), terra_indigena (bool), quilombo (bool), watershed, map_image_url, polygon (geometry, PostGIS)

Relacionamentos principais: `users` 1—N `conversations`; `conversations` 1—N `messages`/`attachments`, 1—1 `geospatial_results`, 1—N `proposals`; `proposals` 1—1 `project_pricings`; `project_pricings` 1—N `proposal_professionals`.

---

## 5. Motor de precificação (detalhado)

Entradas: tipo de estudo (confirmado pela IA), municípios/distância logística, sobreposições geoespaciais.

1. **Template do tipo de estudo** define a composição padrão de profissionais × horas (ex.: EIA-RIMA = Pedro 30d + Beth 7d + Sara 10d campo + Fauna terceiro + Flora terceiro...).
2. **Ajuste manual**: grade editável (Profissional × Entregável × Horas), recalcula em tempo real.
3. **Cálculo**:
   - `C1` = horas escritório × taxa escritório
   - `C2` = horas campo × taxa campo
   - `C3` = subtotal profissional = (C1 + C2) × BDI × impostos
   - `C4` = logística = distância × parâmetros (diárias + combustível + hotel + alimentação)
   - `C5` = custos externos (ARTs, terceiros: fauna, flora, drone)
   - `C6` = TOTAL = Σ profissionais + logística + externos
4. Parâmetros do sistema: tabela de profissionais com taxa/dia por escritório e campo; BDI 1.15–1.30 e impostos ADM 1.25 (configuráveis por contrato); parâmetros de logística (aluguel, combustível, hospedagem).
5. Saídas: tabela de preço auditável por linha, cronograma de desembolso por parcelas, dados prontos para o PDF.

---

## 6. Pipeline de processamento de dados

Após confirmação na tela de setup, arquivos vão para Active Storage (criptografado) e disparam 3 jobs em paralelo:

- **ProcessTR**: extração de texto (ou envio nativo do PDF/DOCX pra Claude) → IA identifica tipo de licença, tipo de estudo, órgão ambiental, municípios, diagnósticos, condicionantes, ressalvas.
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

## 8. Geração do PDF

Processo em duas etapas, com responsabilidades separadas:

1. A IA produz um **texto estruturado** com todo o conteúdo (seções, dados, escopo, equipe, valores), guiada pelo "Prompt de Geração de Proposta".
2. O backend Rails recebe esse texto e monta o PDF com **layout padronizado** (Grover): capa, revisões, carta de apresentação, dados, objetivo, escopo, documentos, produtos, responsabilidades, equipe, prazo, dados bancários, assinaturas.

O layout visual (fontes, cores, margens, logotipos) é controlado 100% pelo código — nunca pela IA. Isso garante consistência visual entre propostas independente do conteúdo gerado.

O usuário pode pedir ajustes de conteúdo via chat a qualquer momento; a IA gera novo texto estruturado e o backend remonta o PDF (nova versão).

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
- Exportação em DOCX (só PDF nesta versão).

---

## 12. Convenções do projeto

- Stack gerado com `rails new papyrus_propostas -d postgresql --css=tailwind` (Rails 8.1, Hotwire/Turbo/Stimulus por padrão).
- Autenticação: usar o gerador nativo (`bin/rails generate authentication`), não Devise.
- Jobs/WebSocket: usar Solid Queue + Solid Cable (já no Gemfile), não introduzir Redis/Sidekiq salvo necessidade concreta.
- PostGIS: adicionar `activerecord-postgis-adapter`, habilitar extensão `postgis` via migration, ajustar `config/database.yml` para adapter `postgis`.
- Preço é sempre calculado em Ruby, nunca pela IA — a IA só alimenta parâmetros de escopo (tipo de estudo, distância, sobreposições) que entram no motor de cálculo.
- Layout do PDF é código (templates HTML/CSS + Grover), não gerado pela IA.
- IA: usar a gem `ruby_llm` (não chamar a API da Anthropic diretamente). Instalada via `rails generate ruby_llm:install chat:Conversation message:Message` — por isso `Conversation` usa `acts_as_chat` e `Message` usa `acts_as_message` (gem renomeia associações automaticamente, ex.: `acts_as_message chat: :conversation`). `ToolCall` e `Model` mantêm os nomes padrão da gem. Configuração em `config/initializers/ruby_llm.rb` (`anthropic_api_key`, `default_model`); rodar `bin/rails ruby_llm:load_models` para popular a tabela `models` assim que a chave real da Anthropic estiver configurada.
- Anexos de conversa (TR, KMZ, complementares) são Active Storage nativo (`has_many_attached :attachments` em `Message`), não uma tabela `attachments` própria.
