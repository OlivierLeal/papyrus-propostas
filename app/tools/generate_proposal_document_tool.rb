# Ferramenta que a IA chama quando o consultor pede pra gerar a Proposta Técnica e/ou Comercial.
# Só o TEXTO (prosa) vem da IA — preço e equipe vêm direto do banco (ProjectPricing/
# ProposalProfessional), nunca da IA. Ver CLAUDE.md seção 8/9. O formato do documento (único ou
# separado) também vem do banco (`Proposal#document_split`) na maioria das vezes — decidido
# sozinho ao ler o ET/TR na criação da proposta, ou trocado manualmente na Tela de Precificação/
# Aprovação — mas a IA pode mudá-lo a partir de um pedido EXPLÍCITO no chat via `formato_documento`
# (2026-09, ver param abaixo); fora desse pedido explícito, ela nunca decide isso sozinha.
#
# A proposta comercial/combinada sai sempre que pedida, em qualquer status (2026-09, pedido do
# consultor — antes exigia "priced"/"approved", obrigando um ciclo "gera sem preço → aprova →
# pede de novo" só pra ver o documento completo). Continua sem bloquear NADA por causa disso —
# só avisa (#price_review_warning) quando o status ainda é "draft", porque BDI/taxas podem estar
# nos defaults (equipe/horas do template padrão ou já sugeridas pela IA). Ver #execute.
#
# Recebe `conversation:`, não `proposal:` — a Proposal pode nem existir ainda (o consultor nunca
# clicou em "Avançar para Precificação"). Achado na prática: exigir isso antes de QUALQUER geração,
# inclusive só-técnica, deixava o fluxo sem sentido pro consultor ("não quero avançar pra preço,
# quero só a técnica"). Agora #execute cria a proposta sozinha (Conversation#ensure_proposal!) na
# primeira vez que a ferramenta é chamada de verdade — o botão continua existindo pra quem prefere
# ir direto pra Tela de Precificação, mas deixou de ser pré-requisito pra gerar a técnica pelo chat.
# Chama `ensure_proposal!(ai_suggestions: false)` — NUNCA `true` daqui: essa criação acontece
# DENTRO de uma tool call (reentraria Conversation#complete se pedisse sugestão de equipe/
# cronograma à IA agora — ver o comentário de ensure_proposal! em conversation.rb). A equipe sai
# do template padrão (determinístico, mesmo fallback de sempre) e o cronograma fica pro
# #ensure_schedule_background_work! logo abaixo, que enfileira em background.
class GenerateProposalDocumentTool < RubyLLM::Tool
  description <<~DESC
    Gera o(s) arquivo(s) .docx da proposta preenchidos, usando o texto que você escrever pra
    cada seção (baseado no ET, no TR quando houver, nos documentos complementares e em propostas anteriores
    semelhantes já analisados nesta conversa) e os dados de preço/equipe que já existem no
    sistema. Gera a versão COMPLETA (comercial, ou o documento combinado) sempre que pedido, mesmo
    com o preço ainda em "draft" — nesse caso a mensagem de retorno avisa que o preço ainda não
    foi revisado na Tela de Precificação, pra você repassar ao consultor. Só chame depois de
    confirmar que não falta nenhuma informação que bloqueia a proposta (ver
    passo a passo interno). Nomes que você não tiver certeza, escreva "A confirmar" em vez de
    inventar. CNPJ é diferente (pedido da Charlene, 2026-09): sem certeza do número, mande
    cnpj_cliente como string vazia (nunca "A confirmar", "[confidencial]" nem qualquer texto de
    preenchimento) — o campo sai em branco no documento, sem inventar nem sinalizar nada no
    lugar do número.

    Por padrão gera técnica+comercial juntas (documento combinado) ou, se o formato já estiver
    marcado como separado, os dois arquivos (técnica e comercial). Use somente_tecnica ou
    somente_comercial só quando o consultor pedir EXPLICITAMENTE um dos dois lados sozinho — nunca
    os dois parâmetros juntos. Use formato_documento só quando o consultor pedir, pelo CHAT, pra
    mudar entre documento único e documentos separados dali pra frente.

    NUNCA escreva códigos de citação "[F12]" em nenhum parâmetro de texto desta ferramenta —
    esse formato só existe pra virar link no CHAT (bloco [ACHADOS DESTA PROPOSTA]), não tem
    nenhum sentido no documento final que o CLIENTE lê. Se for relevante citar de onde uma
    informação veio, escreva por extenso dentro da própria frase (ex.: "conforme informado no
    ET", "conforme o Termo de Referência", "conforme condicionante do IPHAN") — nunca a marca
    entre colchetes.

    Ao se referir à prestadora do serviço no texto das seções, escreva sempre "a Papyrus"
    (ou "PAPYRUS") — nunca "a CONTRATADA" nem "a Contratada". O modelo já usa "PAPYRUS" nas
    obrigações e no prazo; o texto que você escrever tem que seguir o mesmo termo.

    Parágrafos curtos: no máximo ~5 linhas cada. Se um parágrafo ficar mais longo que isso,
    quebre em dois ou mais. Vale principalmente para objetivo_dos_servicos,
    caracterizacao_do_empreendimento e os parágrafos introdutórios do escopo.

    No texto das seções, refira-se ao órgão licenciador e aos demais órgãos de forma GENÉRICA:
    "o órgão ambiental", "o órgão ambiental licenciador", "o órgão interveniente", "os órgãos
    intervenientes". NÃO escreva o nome nem a sigla de nenhum deles (INEMA, IBAMA, FEPAM, CETESB,
    INEA, SEMA, SPRH, nem sistema interno tipo SEI/SEIA/e-Protocolo), mesmo que apareçam nos
    achados ou nos documentos desta conversa. O texto da proposta tem que servir pra qualquer
    caso — a identificação do órgão específico é usada no estudo e nos achados, não vai no corpo
    do documento entregue ao cliente.

    A proposta NUNCA pode dar a entender que algum serviço/diagnóstico/entregável é
    terceirizado, subcontratado ou executado por outra empresa — mesmo que o "ESTADO ATUAL DA
    PROPOSTA" ou os achados desta conversa mencionem "Serviços Terceirizados" na precificação
    (isso é só um campo interno de custo, o cliente nunca vê essa informação). Escreva TODO
    entregável como se fosse executado pela própria Papyrus — nunca use "terceirizado",
    "subcontratado", "quarteirizado", "parceiro externo" nem equivalente em nenhum parâmetro
    desta ferramenta.
  DESC

  param :nome_cliente, desc: "Razão social do cliente/contratante, EXATAMENTE como aparece no ET/documentos, " \
    "com a acentuação correta (ex.: \"Comércio e Exportação Mineração Bahia Quartzo Ltda\", nunca " \
    "\"Comercio e Exportacao\"). O sistema coloca em maiúsculas sozinho no cabeçalho."
  param :contato_cliente, desc: "Nome da pessoa de contato no cliente, SEM tratamento (ex.: \"Lincoln Juvenal\"), " \
    "ou \"A confirmar\" se não souber"
  param :tratamento_contato,
    desc: "\"Sr.\" ou \"Sra.\" para a pessoa de contato — deduza pelo nome ou por como o ET/e-mail se refere a " \
          "ela. Define \"Att.: Sr./Sra. Nome\" e a saudação \"Prezado Sr.\"/\"Prezada Sra.\". Deixe de fora se " \
          "não houver contato definido.",
    required: false
  param :descricao_servico, desc: "Descrição curta do serviço (ex.: \"elaboração de EIA/RIMA do Parque Eólico X\")"
  param :municipios, desc: "Município(s) do empreendimento"
  param :estado, desc: "Sigla do estado (ex.: BA)"
  param :cnpj_cliente, desc: "CNPJ do cliente. Sem certeza do número, mande string vazia \"\" — NUNCA \"A " \
    "confirmar\", \"[confidencial]\" ou qualquer texto no lugar do número; o campo fica em branco no " \
    "documento (pedido da Charlene, 2026-09)."
  param :objetivo_dos_servicos, desc: "Texto da seção 'Objetivo dos Serviços' — CURTO, no máximo 2 frases: só O QUÊ e PRA QUÊ " \
    "(qual serviço/assessoria, para qual ato de licenciamento, do empreendimento com suas características essenciais — " \
    "nº de aerogeradores/MW/etc. — e onde). NÃO descreva aqui o que o serviço abrange, as etapas, a metodologia ou o " \
    "que será diagnosticado: isso é escopo_e_metodologia/topicos_escopo. NUNCA comece com preâmbulo/blablabla " \
    "genérico — frases como \"O presente serviço abrange…\", \"considerando que…\", \"por meio da presente " \
    "proposta…\" ou qualquer detalhamento de execução NÃO entram nesta seção; vá direto ao ponto. Comece SEMPRE " \
    "com um verbo no infinitivo (\"Realizar\", \"Elaborar\", \"Prestar\"…), nunca no gerúndio/presente " \
    "(\"Realizando\"/\"Realiza\"). Exemplo do formato esperado: \"Realizar Assessoria Estratégica e Elaboração de " \
    "Estudos Técnicos para Licenciamento Ambiental de [empreendimento], junto ao órgão ambiental estadual, com " \
    "área de aproximadamente X m², localizado no município de Y, estado de Z.\""
  param :caracterizacao_do_empreendimento, desc: "Texto da seção 'Caracterização do Empreendimento' — só a descrição FACTUAL do " \
    "empreendimento: o que é, onde fica, composição (sub-parques, aerogeradores, potência), e o histórico da licença " \
    "quando houver (processo nº, data de publicação, validade). NÃO escreva aqui o que a proposta/serviço vai fazer " \
    "(\"a presente proposta refere-se a…\", \"com foco na atualização de…\") — isso é escopo. Quebre em 2+ parágrafos; " \
    "nunca um único parágrafo longo."
  param :nome_documento_tr, desc: "Nome do documento de ET (Pedido Técnico do Estudo) usado como base do escopo — " \
    "o nome do parâmetro ficou de antes da separação ET/TR, mas o valor esperado é o do ET, o documento principal"
  param :escopo_e_metodologia, desc: "Parágrafo(s) INTRODUTÓRIOS da seção 'Escopo e Metodologia' — contexto geral de " \
    "como o serviço será executado, antes de entrar nos tópicos (ver topicos_escopo). Se o escopo for simples " \
    "demais pra render nenhum tópico à parte, pode ser o texto inteiro da seção."
  param :topicos_escopo, type: "array", required: false,
    desc: "Etapas do PROCESSO de execução do serviço — não é um resumo do que será diagnosticado (isso já está em " \
          "caracterizacao_do_empreendimento/objetivo_dos_servicos), é como a Papyrus vai EXECUTAR: reuniões, " \
          "vistorias, tramitação junto ao órgão, cada estudo/produto intermediário que compõe o serviço. Pense " \
          "nas etapas reais do trabalho, na ordem em que acontecem, por exemplo (adapte ao que o ET/TR e a " \
          "equipe/precificação desta proposta realmente preveem — nem toda proposta tem todas): " \
          "enquadramento/classificação legal do empreendimento; reunião de kick-off (quantos profissionais); " \
          "assessoria para tramitação do processo junto ao órgão (protocolo, acompanhamento, quantas vistorias " \
          "técnicas, quantas reuniões com o órgão); o(s) diagnóstico(s)/estudo(s) em si (pode dividir por meio " \
          "físico/biótico/socioeconômico aqui dentro, se fizer sentido); cada produto intermediário que tiver " \
          "etapa própria (ex.: estudos arqueológicos com suas fichas/relatórios específicos, inventário florestal, " \
          "reunião pública, planos e programas ambientais); geoprocessamento/cartografia, quando for entrega " \
          "própria. Cada item no formato \"Título | Texto da etapa\" (ex.: \"Reunião Kick Off | Será realizada 01 " \
          "reunião de abertura do contrato, com participação de 02 profissionais...\"). Números de vistorias, " \
          "reuniões, dias e campanhas de campo têm que vir do que já está definido nesta proposta ([ESTADO ATUAL " \
          "DA PROPOSTA]/achados do ET-TR) — nunca invente quantidade; se não souber, descreva a atividade sem " \
          "quantificar. O sistema numera cada item como subtópico da seção (5.1, 5.2...) e destaca o título em " \
          "negrito — não escreva o número nem \"5.\" você mesma, nem tente negritar com texto. Use o " \
          "search_historical_archive pra ver como a Papyrus estruturou o escopo de projetos parecidos antes de " \
          "escrever — a estrutura processual varia bastante por tipo de estudo e vale seguir o padrão já usado."
  param :prazo_de_execucao, required: false,
    desc: "Prazo contratual, por extenso (ex.: \"120 dias corridos\"). Texto independente da " \
    "tabela/infográfico do cronograma (Quadro/Figura N-1) — mudar só este texto não reconstrói o cronograma; " \
    "pra isso, use atualizar_cronograma. Sem informação clara no ET/TR, pode deixar de fora — o sistema usa " \
    "\"12 (doze) meses contratuais\" como padrão automaticamente (pedido da Charlene, 2026-09), nunca invente " \
    "um número pra preencher a lacuna."
  param :produtos, type: "array",
    desc: "Lista dos produtos/entregáveis — tem que bater com o que topicos_escopo descreve: cada etapa que gera " \
          "um documento próprio (o estudo/diagnóstico principal, mas também fichas, relatórios e certidões " \
          "intermediárias de cada produto específico do escopo — ex.: um estudo arqueológico costuma gerar FCA, " \
          "PAIPA e RAIPA como produtos separados, não só \"Estudos Arqueológicos\"; inventário florestal, planos " \
          "e programas ambientais, relatório de reunião pública e certidão/certificado da licença também são " \
          "produtos próprios quando essas etapas existirem no escopo). Não invente produto que não tenha etapa " \
          "correspondente no escopo. Cada item pode trazer o formato depois de uma barra vertical " \
          "(ex.: \"Estudo Ambiental para Atividades de Médio Impacto (EMI) | Word e PDF\"); sem a barra, " \
          "o sistema usa \"Digital (PDF)\". Um item terminado em dois-pontos e sem formato vira uma linha de " \
          "AGRUPAMENTO no quadro (ex.: \"Licença Prévia (LP):\") — use isso para separar os produtos por fase " \
          "do licenciamento quando a proposta tiver mais de uma fase, como a Papyrus faz."

  param :itens_nao_previstos, type: "array", required: false,
    desc: "O que esta proposta NÃO cobre, um item por linha (ex.: \"Execução dos planos e programas ambientais\", " \
          "\"Regularização fundiária\", \"Tratativas junto a INCRA ou FUNAI\"). Vira o capítulo \"ITENS NÃO " \
          "PREVISTOS\" (seção própria do documento) — é o que impede o cliente de cobrar depois um serviço que " \
          "não foi orçado. Liste só o que for específico deste projeto; a frase padrão sobre proposta " \
          "complementar o modelo já traz fixa nesse capítulo. Sem nada específico, pode deixar de fora. " \
          "PADRÃO DA PAPYRUS (pedido da Charlene, 2026-09): inclua SEMPRE estes dois itens, A NÃO SER que o " \
          "ET/TR desta proposta peça explicitamente por eles como parte do escopo contratado (nesse caso eles " \
          "entram em produtos/topicos_escopo, não aqui): \"Planejamento, organização e realização de reunião " \
          "e/ou audiência pública.\" e \"Estudos de comunidades tradicionais, espeleológicos, paleontológico, " \
          "dentre outros para atendimentos de exigências de órgãos intervenientes.\""
  param :nome_arquivo,
    desc: "SÓ quando o consultor disser como o arquivo deve se chamar (ex.: \"o arquivo tem que se chamar " \
          "PTC26002_PMM_LU_Simões Filho_BA\"). Copie o nome exatamente como ele escreveu, sem inventar, sem " \
          "completar e sem a extensão .docx — o sistema cuida da revisão (_Rev.NN) e de distinguir técnica de " \
          "comercial. Se ele não falou nada sobre nome de arquivo, NÃO envie este parâmetro: o sistema usa o " \
          "padrão da Papyrus. Envie \"padrão\" se ele pedir para voltar ao nome automático.",
    required: false

  param :atualizar_cronograma, type: "boolean", required: false,
    desc: "true SOMENTE quando o consultor pede uma MUDANÇA num cronograma que esta proposta JÁ " \
          "TEM (ex.: \"mude para 6 meses\", \"o cliente pediu pra reduzir o prazo\", \"remonte o " \
          "cronograma considerando X\"). IMPORTANTE: mudar só o texto de prazo_de_execucao NÃO " \
          "altera a tabela/infográfico do cronograma — são coisas independentes. Sem este " \
          "parâmetro, um cronograma que já existe NUNCA é reconstruído: as próximas gerações " \
          "reaproveitam exatamente as mesmas fases/atividades/semanas já salvas, mesmo que o " \
          "texto do prazo mude — a ferramenta só LÊ o cronograma do banco, nunca escreve nele. " \
          "Ao marcar true, o cronograma é reconstruído do zero em segundo plano considerando o " \
          "pedido (a partir do histórico desta conversa) — avise o consultor pra pedir a geração " \
          "de novo em alguns instantes. Não marque true numa proposta que ainda não tem " \
          "cronograma nenhum (isso já acontece sozinho, sem precisar deste parâmetro)."

  param :data_inicio_cronograma_servico,
    desc: "SÓ quando o consultor disser no chat a data de início do Cronograma do Serviço (ex.: \"o cronograma " \
          "começa em 15/10\"). Formato AAAA-MM-DD. Fica gravado e vale pra esta e pras próximas gerações — se ele " \
          "não disse nada sobre isso, NÃO envie este parâmetro: o sistema usa o que já está na Tela de " \
          "Precificação, ou presume o início do mês que vem se ainda não houver nenhuma data definida.",
    required: false
  param :data_inicio_cronograma_implantacao,
    desc: "Mesma ideia de data_inicio_cronograma_servico, mas pro Cronograma de Implantação do Empreendimento " \
          "(a obra/operação do CLIENTE, não o serviço da Papyrus) — só quando o consultor falar essa data " \
          "especificamente. Formato AAAA-MM-DD.",
    required: false

  param :exportar_cronograma_ms_project, type: "boolean", required: false,
    desc: "true SOMENTE em dois casos: (1) o consultor pediu explicitamente no chat o cronograma em formato " \
          "MS Project (ex.: \"manda também em .xml\", \"preciso importar no MS Project\"), ou (2) o ET ou o TR " \
          "exige a entrega do cronograma nesse formato. Fora desses dois casos, NÃO envie este parâmetro (ou " \
          "envie false) — a maioria das propostas não precisa do arquivo extra, e a tabela do cronograma dentro " \
          "do próprio .docx sai sempre, com ou sem isto. Não repita a exportação sozinha nas gerações seguintes " \
          "só porque saiu uma vez — cada geração decide de novo com base no que está acontecendo nesta."

  param :descricao_revisao, desc: "Resumo curto do que mudou desde a última geração (ex.: \"Ajuste de escopo conforme pedido do consultor\"). " \
    "Ignorado na 1ª geração da proposta — o sistema sempre usa \"Emissão Inicial\" nesse caso — mas o parâmetro deve ser enviado mesmo assim."

  param :somente_tecnica, type: "boolean", required: false,
    desc: "true SOMENTE quando o consultor pede EXPLICITAMENTE só a parte técnica (ex.: \"gera só a técnica " \
          "por enquanto\", \"ainda não quero mostrar preço\"). Por padrão (sem este parâmetro, ou false) a " \
          "ferramenta gera o documento COMPLETO (comercial, ou o combinado técnica+comercial) sempre — mesmo " \
          "com o preço ainda em \"draft\" (nesse caso a mensagem de retorno avisa que o preço não foi revisado, " \
          "repasse esse aviso ao consultor). Não marque true só porque o status ainda é \"draft\" — isso não é " \
          "mais motivo pra restringir, só o pedido explícito do consultor é. Nunca marque junto com " \
          "somente_comercial — são mutuamente exclusivos."

  param :somente_comercial, type: "boolean", required: false,
    desc: "true SOMENTE quando o consultor pede EXPLICITAMENTE só a parte comercial (ex.: \"manda só a " \
          "comercial\", \"preciso só do documento de preço agora\"). Por padrão a ferramenta gera o documento " \
          "completo — este parâmetro nunca é o padrão, só o pedido explícito do consultor liga ele. Nunca " \
          "marque junto com somente_tecnica — são mutuamente exclusivos."

  param :formato_documento, required: false,
    desc: "Só quando o consultor pedir EXPLICITAMENTE, no CHAT, pra mudar o formato do documento (ex.: " \
          "\"separa em dois arquivos daqui pra frente\", \"pode juntar tudo num só\", \"não precisa mais " \
          "separar técnica e comercial\"). Valores aceitos: \"separado\" (a partir de agora toda geração sai " \
          "em 2 arquivos, técnica e comercial) ou \"combinado\" (a partir de agora sai 1 arquivo só, com tudo " \
          "junto). A mudança fica valendo pras PRÓXIMAS gerações também, não só nesta. NÃO envie este " \
          "parâmetro só porque o ET/TR pede documentos separados — isso já é decidido sozinho ao criar a " \
          "proposta (lendo o ET/TR), sem precisar de nada seu; use isto só quando for o CONSULTOR pedindo a " \
          "mudança pelo chat, depois da proposta já criada."

  param :obrigacoes_contratante_adicionais, type: "array", required: false,
    desc: "Obrigações EXTRAS da CONTRATANTE (o cliente) além das já fixas no modelo (acesso à área, fornecer " \
          "documentos, pagar taxas do órgão, etc. — não repita essas). Um item por linha, só o que o ET ou o TR " \
          "exigir especificamente deste cliente (ex.: \"Fornecer escolta armada para as vistorias de campo\", " \
          "\"Disponibilizar embarcação para acesso à área insular\"). Não invente — só o que estiver escrito no " \
          "documento. Se nada exigir algo além do padrão, não envie este parâmetro."

  param :obrigacoes_papyrus_adicionais, type: "array", required: false,
    desc: "Obrigações EXTRAS da PAPYRUS (CONTRATADA) além das já fixas no modelo (executar o escopo, usar pessoal " \
          "qualificado, seguir a legislação, etc. — não repita essas). Um item por linha, só o que o ET ou o TR " \
          "exigir especificamente (ex.: \"Emitir relatório mensal de acompanhamento ao órgão financiador\", " \
          "\"Realizar treinamento da equipe do cliente em SST antes do início dos serviços\"). Não invente — só o " \
          "que estiver escrito no documento. Se nada exigir algo além do padrão, não envie este parâmetro."

  # Chamado pelos jobs de sugestão em background (SuggestScheduleJob, SuggestTeamJob,
  # RegenerateScheduleJob) DEPOIS que eles terminam — relato do consultor: gerar a proposta sem
  # cronograma/equipe (porque a IA ainda estava sugerindo em background) e só depois de avisado
  # "peça pra gerar de novo" era ruim — ele queria que o sistema TERMINASSE sozinho, sem precisar
  # pedir de novo. Remonta o .docx com os MESMOS parâmetros de conteúdo da última geração
  # (`proposal.content_json`, gravado em #execute) — nenhuma chamada de IA nova aqui, só reusa o
  # texto que a IA já escreveu antes; os dados que estavam faltando (cronograma/equipe) já estão
  # no banco a esta altura, então o .docx sai completo. Sem geração anterior (`generated_documents`
  # vazio) ou sem `content_json` guardado, não faz nada — não é este método que gera a PRIMEIRA
  # versão. `atualizar_cronograma` é sempre forçado a `false` aqui — sem isso, replay de um args
  # antigo com esse parâmetro `true` reenfileiraria RegenerateScheduleJob, que ao terminar chamaria
  # este método de novo com os MESMOS args → loop infinito.
  def self.replay_pending_regeneration!(proposal)
    return if proposal.generated_documents.none?
    return if proposal.content_json.blank?

    args = proposal.content_json.symbolize_keys.merge(
      atualizar_cronograma: false,
      descricao_revisao: "Complementação automática — cronograma e/ou equipe técnica ficaram prontos em segundo plano"
    )
    result = JSON.parse(new(conversation: proposal.conversation).execute(**args))
    return unless result["success"]

    proposal.conversation.messages.create!(role: "assistant", content: result["message"])
    proposal.conversation.broadcast_refresh
  rescue StandardError => e
    Rails.logger.error("GenerateProposalDocumentTool.replay_pending_regeneration! falhou para proposal #{proposal.id}: #{e.class} #{e.message}")
  end

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute(**args)
    # Rede de segurança: mesmo com a instrução no prompt, a IA às vezes "vaza" os códigos de
    # citação do chat ([F12], ver Message::CITATION_PATTERN) pro texto da proposta — fazem
    # sentido na CONVERSA (ApplicationHelper#render_markdown transforma em link), mas no .docx
    # do cliente aparecem crus, sem sentido nenhum pra quem lê (achado ao vivo em produção).
    args = args.transform_values { |value| strip_citation_codes(value) }

    @proposal = @conversation.proposal || @conversation.ensure_proposal!(ai_suggestions: false)
    return { error: blocked_reason }.to_json if @proposal.nil?

    if somente_tecnica?(args) && somente_comercial?(args)
      return { error: "somente_tecnica e somente_comercial são mutuamente exclusivos — escolha um." }.to_json
    end

    # 2026-09, pedido do consultor: antes só o ET/TR (na criação da proposta) ou a tela decidiam
    # se o documento sai combinado ou separado — pedir a mudança no CHAT não tinha efeito nenhum.
    apply_document_split_override!(args[:formato_documento])

    # Guarda o ÚLTIMO conjunto de parâmetros de conteúdo desta geração — usado por
    # .replay_pending_regeneration! pra remontar o .docx sozinho, sem IA, quando o cronograma/
    # equipe (sugeridos em background) terminam DEPOIS que este documento já saiu (ver abaixo).
    # jsonb aceita os args como vieram (arrays/booleans/strings, sem hash aninhado nos parâmetros
    # desta ferramenta) — símbolo vira string na volta, por isso o `.symbolize_keys` no replay.
    @proposal.update!(content_json: args)

    team_background_task = ensure_team_background_work!
    schedule_background_task = ensure_schedule_background_work!(args)
    ensure_logistics_suggested!
    apply_schedule_start_date_overrides!(args)
    defaulted_schedule_types = default_missing_schedule_dates!

    apply_filename_override!(args[:nome_arquivo])
    @proposal.increment!(:version)
    description = @proposal.version == 1 ? "Emissão Inicial" : args[:descricao_revisao].to_s.presence || "Revisão solicitada pelo consultor"

    filler = ProposalDocxFiller.new(Rails.root.join("app/templates/docx/proposta_tecnica_comercial.docx"))
    images = build_images
    schedules = build_schedules
    placeholders = build_placeholders(args, images)
    tables = build_tables(args, description)
    remove_paragraph_if_blank = OBRIGACOES_ADICIONAIS_TOKENS + %w[ITENS_NAO_PREVISTOS]
    export_ms_project = export_ms_project?(args)

    # 2026-09, pedido do consultor: a comercial/combinado sai sempre que pedido, mesmo com o
    # preço ainda em "draft" (antes só saía a técnica-sozinha até o preço ser revisado/aprovado
    # na Tela de Precificação — isso obrigava um ciclo "gera sem preço → aprova preço → pede de
    # novo" só pra ver o documento completo). Continua sem bloquear NADA — só avisa
    # (#price_review_warning) quando o status ainda é "draft", porque BDI/taxas podem estar nos
    # defaults (inclusive profissionais com valor da hora-homem/diária ainda em 0,00, ver CLAUDE.md
    # seção 5) e o valor impresso pode não refletir o que a Papyrus vai cobrar de verdade.
    if somente_tecnica?(args)
      technical_filename = @proposal.docx_filename("tecnica")
      files = filler.fill_split(
        placeholders: placeholders, tables: tables, images: images, schedules: schedules, remove_paragraph_if_blank: remove_paragraph_if_blank,
        technical_overrides: { "TITULO_LINHA2" => "TÉCNICA", "TITULO_LINHA3" => "", "NUMERO_PROPOSTA" => @proposal.docx_numero_capa("tecnica") }
      )
      attach!(files[:technical], technical_filename, "tecnica", description)
      failed_schedule_types = []
      schedule_filenames = export_ms_project ? attach_schedule_mspdi_files!(schedules, args, description, failed_schedule_types) : []
      { success: true, version: @proposal.version, filenames: [ technical_filename, *schedule_filenames ],
        message: "Gerado o arquivo #{technical_filename} — só a parte técnica, a pedido do consultor. " \
          "Peça \"gerar completo\"/\"com a comercial\" quando quiser o documento inteiro." \
          "#{schedule_message(schedule_filenames, defaulted_schedule_types, schedule_background_task, failed_schedule_types, team_background_task: team_background_task)}" }.to_json
    elsif somente_comercial?(args)
      commercial_filename = @proposal.docx_filename("comercial")
      files = filler.fill_split(
        placeholders: placeholders, tables: tables, images: images, schedules: schedules, remove_paragraph_if_blank: remove_paragraph_if_blank,
        commercial_overrides: { "TITULO_LINHA2" => "COMERCIAL", "TITULO_LINHA3" => "", "NUMERO_PROPOSTA" => @proposal.docx_numero_capa("comercial") }
      )
      attach!(files[:commercial], commercial_filename, "comercial", description)
      failed_schedule_types = []
      schedule_filenames = export_ms_project ? attach_schedule_mspdi_files!(schedules, args, description, failed_schedule_types) : []
      { success: true, version: @proposal.version, filenames: [ commercial_filename, *schedule_filenames ],
        message: "Gerado o arquivo #{commercial_filename} — só a parte comercial, a pedido do consultor. " \
          "Peça \"gerar completo\"/\"com a técnica\" quando quiser o documento inteiro.#{price_review_warning}" \
          "#{schedule_message(schedule_filenames, defaulted_schedule_types, schedule_background_task, failed_schedule_types, team_background_task: team_background_task)}" }.to_json
    elsif @proposal.document_split == "separated"
      technical_filename = @proposal.docx_filename("tecnica")
      commercial_filename = @proposal.docx_filename("comercial")
      files = filler.fill_split(
        placeholders: placeholders, tables: tables, images: images, schedules: schedules, remove_paragraph_if_blank: remove_paragraph_if_blank,
        technical_overrides: { "TITULO_LINHA2" => "TÉCNICA", "TITULO_LINHA3" => "", "NUMERO_PROPOSTA" => @proposal.docx_numero_capa("tecnica") },
        commercial_overrides: { "TITULO_LINHA2" => "COMERCIAL", "TITULO_LINHA3" => "", "NUMERO_PROPOSTA" => @proposal.docx_numero_capa("comercial") }
      )
      attach!(files[:technical], technical_filename, "tecnica", description)
      attach!(files[:commercial], commercial_filename, "comercial", description)
      failed_schedule_types = []
      schedule_filenames = export_ms_project ? attach_schedule_mspdi_files!(schedules, args, description, failed_schedule_types) : []
      { success: true, version: @proposal.version, filenames: [ technical_filename, commercial_filename, *schedule_filenames ],
        message: "Gerados 2 arquivos: #{technical_filename} e #{commercial_filename} (versão #{@proposal.version}), " \
          "disponíveis na Tela de Precificação.#{price_review_warning}#{schedule_message(schedule_filenames, defaulted_schedule_types, schedule_background_task, failed_schedule_types, team_background_task: team_background_task)}" }.to_json
    else
      combined_filename = @proposal.docx_filename("combined")
      bytes = filler.fill(placeholders: placeholders, tables: tables, images: images, schedules: schedules, remove_paragraph_if_blank: remove_paragraph_if_blank)
      attach!(bytes, combined_filename, "combined", description)
      failed_schedule_types = []
      schedule_filenames = export_ms_project ? attach_schedule_mspdi_files!(schedules, args, description, failed_schedule_types) : []
      { success: true, version: @proposal.version, filenames: [ combined_filename, *schedule_filenames ],
        message: "Gerado o arquivo #{combined_filename}, disponível na Tela de Precificação.#{price_review_warning}#{schedule_message(schedule_filenames, defaulted_schedule_types, schedule_background_task, failed_schedule_types, team_background_task: team_background_task)}" }.to_json
    end
  rescue StandardError => e
    Rails.logger.error("GenerateProposalDocumentTool falhou para proposal #{@proposal.id}: #{e.class} #{e.message}")
    { error: "Não consegui gerar o documento agora. Tente novamente em instantes." }.to_json
  end

  private
    # "Att.: Sr. Lincoln Juvenal" + "Prezado Sr." / "Att.: Sra. Maria" + "Prezada Sra." (2026-09-28,
    # pedido do consultor — o modelo tinha "Sr." e "Prezado Sr." fixos, errados pra contato mulher).
    # Sem contato definido: "A confirmar" + "Prezados Senhores". Tratamento não informado cai no
    # "Sr." de sempre (o comportamento antigo do modelo). Tratamento escrito no nome ("Sra. Maria")
    # também vale, e nunca duplica.
    CONTACT_TITLE = /\A\s*(sr|sra|srª|dr|dra|eng|engª)\.?\s+/i
    GREETINGS = { "Sr." => "Prezado Sr.", "Sra." => "Prezada Sra." }.freeze

    def contact_greeting(args)
      raw = args[:contato_cliente].to_s.strip
      name = raw.sub(CONTACT_TITLE, "").strip
      return [ "A confirmar", "Prezados Senhores" ] if name.blank? || name.match?(/\Aa confirmar\z/i)

      title = normalize_title(args[:tratamento_contato]) || normalize_title(raw[CONTACT_TITLE, 1]) || "Sr."
      [ "#{title} #{name}", GREETINGS.fetch(title) ]
    end

    def normalize_title(value)
      case value.to_s.strip.downcase.delete(".")
      when "sr", "senhor", "dr", "eng" then "Sr."
      when "sra", "srª", "senhora", "dra", "engª" then "Sra."
      end
    end

    # A mensagem antiga ("falta o tipo de estudo ser identificado (ET ainda em processamento) ou a
    # revisão ser concluída") juntava duas causas diferentes e apontava pra uma terceira que
    # normalmente já não é verdade. Na conversa 31 (produção) o ET estava "done" havia 15 minutos e
    # o que faltava era cadastro de tipo de estudo — a IA leu "ET ainda em processamento", concluiu
    # que era falha do backend, repetiu a chamada quatro vezes e mandou o consultor procurar o time
    # de desenvolvimento. Cada causa agora diz o que ela é e onde se resolve.
    # Desde 2026-09 uma proposta pode ter N tipos de estudo ou nenhum (acompanhamento) — não é
    # mais motivo pra recusar criar a proposta (ver Conversation#ensure_proposal!). O único motivo
    # real que resta é a conversa ainda não estar em "reviewing" (documentos em processamento).
    def blocked_reason
      "Não dá pra criar a proposta agora: os documentos ainda estão sendo processados " \
      "(situação atual: #{@conversation.status_label}). Avise o consultor e tente de novo quando " \
      "o processamento terminar."
    end

    # 2026-09: a comercial/combinado não fica mais bloqueada por status — este aviso é o que
    # substitui a antiga trava, repassado na mensagem de retorno pra IA passar ao consultor.
    def price_review_warning
      return "" unless @proposal.status == "draft"

      " ⚠️ O preço ainda não foi revisado na Tela de Precificação (status \"draft\") — confira " \
      "BDI, taxas e equipe antes de enviar este documento ao cliente."
    end

    # Item de lista opcional no modelo (7.1/7.2 — ver ProposalDocxFiller#fill_simple_placeholders!)
    # — some o parágrafo inteiro em vez de deixar um "●" sem texto quando não há nada extra.
    OBRIGACOES_ADICIONAIS_TOKENS = %w[OBRIGACOES_CONTRATANTE_ADICIONAIS OBRIGACOES_PAPYRUS_ADICIONAIS].freeze

    # O consultor às vezes dita o nome do arquivo no chat ("tem que se chamar PTC26002_PMM..."),
    # normalmente porque a pasta na rede e o controle de propostas já foram criados com aquele
    # nome (itens 1 e 2 do passo a passo interno). A partir daí é esse o nome, inclusive nas
    # versões seguintes — por isso fica gravado na proposta, e não só nesta geração.
    RESET_WORDS = %w[padrao padrão default automatico automático].freeze

    def apply_filename_override!(nome)
      nome = nome.to_s.strip
      return if nome.blank?

      @proposal.update!(docx_filename_override: RESET_WORDS.include?(nome.downcase) ? nil : nome)
    end

    # Só o mapa real da Mapbox (PNG) entra no .docx — o croqui SVG de reserva (quando a Mapbox
    # não está disponível) não tem como virar imagem embutida do Word sem conversão, então nesse
    # caso o placeholder cai no fluxo de texto normal e sai em branco (ver build_placeholders).
    def build_images
      area_image = @proposal.conversation.geospatial_result&.area_image
      return {} unless area_image&.attached? && area_image.content_type == "image/png"

      { "MAPA_AREA_ESTUDO" => area_image.download }
    end

    # Cronograma (ver ScheduleItem/ScheduleTableBuilder/ProposalDocxFiller#insert_schedule_
    # tables!) — já mora no banco desde a criação da proposta (Proposal#build_with_ai_suggested_
    # schedule!) e é ajustável na Tela de Precificação, então não é a IA quem manda isso pro
    # gerador, é lido direto daqui, igual equipe e desembolso. Um tipo sem data de início setada
    # (ou sem nenhum item) fica de fora silenciosamente — a página só existe quando os dois estão
    # presentes.
    def build_schedules
      pricing = @proposal.project_pricing
      return {} unless pricing

      {
        "servico" => schedule_payload(pricing, "servico", pricing.schedule_papyrus_start_date),
        "implantacao" => schedule_payload(pricing, "implantacao", pricing.schedule_empreendimento_start_date)
      }.compact
    end

    def schedule_payload(pricing, type, start_date)
      items = pricing.schedule_items.select { |item| item.schedule_type == type }
      return nil if items.empty? || start_date.blank?

      payload = { start_date: start_date, items: items }
      # Só o cronograma do serviço tem os ≤6 marcos que a IA elegeu pro infográfico — o de
      # implantação segue com um círculo por fase. Se a IA ainda não elegeu (ou job pendente),
      # usa seleção determinística de até 6 marcos padrão para nunca exceder 6 círculos.
      if type == "servico"
        payload[:key_points] = pricing.schedule_key_points.presence || @proposal.default_schedule_key_points
      end
      payload
    end

    def build_placeholders(args, images)
      {
        "NUMERO_PROPOSTA" => @proposal.docx_numero_capa("combined"),
        "REVISAO_ATUAL" => format("%02d", @proposal.version - 1),
        "TITULO_LINHA2" => "TÉCNICA E",
        "TITULO_LINHA3" => "COMERCIAL",
        "DATA_EMISSAO_INICIAL" => Date.current.strftime("%d/%m/%Y"),
        # Cabeçalho "A / NOME DO CLIENTE": maiúsculas DE VERDADE, com acento (2026-09-28, pedido da
        # Charlene com print: o modelo usava versalete, que só simula maiúscula por cima do texto
        # como ele veio — "Comercio e Exportacao" em vez de "COMÉRCIO E EXPORTAÇÃO").
        "NOME_CLIENTE" => args[:nome_cliente].to_s.upcase,
        "CONTATO_CLIENTE" => contact_greeting(args).first,
        "SAUDACAO" => contact_greeting(args).last,
        "DESCRICAO_SERVICO" => args[:descricao_servico],
        "MUNICIPIOS" => args[:municipios],
        "ESTADO" => args[:estado],
        "REF_LINHA" => build_ref_linha(args),
        "CNPJ_CLIENTE" => args[:cnpj_cliente],
        "NOME_CLIENTE_ASSINATURA" => args[:nome_cliente],
        "OBJETIVO_SERVICOS" => args[:objetivo_dos_servicos],
        "CARACTERIZACAO_EMPREENDIMENTO" => args[:caracterizacao_do_empreendimento],
        "NOME_DOCUMENTO_TR" => args[:nome_documento_tr],
        "ESCOPO_METODOLOGIA" => escopo_e_topicos(args),
        "ITENS_NAO_PREVISTOS" => build_itens_nao_previstos(args),
        "PRAZO_EXECUCAO" => prazo_execucao_value(args),
        "PRECO_TOTAL" => @proposal.docx_total_price,
        "OBRIGACOES_CONTRATANTE_ADICIONAIS" => join_lines(args[:obrigacoes_contratante_adicionais]),
        "OBRIGACOES_PAPYRUS_ADICIONAIS" => join_lines(args[:obrigacoes_papyrus_adicionais])
      }.tap { |placeholders| placeholders["MAPA_AREA_ESTUDO"] = "" if images.empty? }
    end

    # Linha "Ref.:" montada aqui (não mais um texto fixo no modelo) só pra resolver a concordância:
    # o modelo trazia "nos municípios de {{MUNICIPIOS}}" cravado no plural e saía errado com um
    # município só (achado real, revisão QAIR). A preposição do estado ("da Bahia" / "de São Paulo"
    # / "do Pará") vem de UF_ARTIGO — Distrito Federal não leva "estado".
    UF_NOMES = {
      "AC" => "Acre", "AL" => "Alagoas", "AP" => "Amapá", "AM" => "Amazonas", "BA" => "Bahia",
      "CE" => "Ceará", "DF" => "Distrito Federal", "ES" => "Espírito Santo", "GO" => "Goiás",
      "MA" => "Maranhão", "MT" => "Mato Grosso", "MS" => "Mato Grosso do Sul", "MG" => "Minas Gerais",
      "PA" => "Pará", "PB" => "Paraíba", "PR" => "Paraná", "PE" => "Pernambuco", "PI" => "Piauí",
      "RJ" => "Rio de Janeiro", "RN" => "Rio Grande do Norte", "RS" => "Rio Grande do Sul",
      "RO" => "Rondônia", "RR" => "Roraima", "SC" => "Santa Catarina", "SP" => "São Paulo",
      "SE" => "Sergipe", "TO" => "Tocantins"
    }.freeze
    UF_ARTIGO = {
      "AC" => "do", "AL" => "de", "AP" => "do", "AM" => "do", "BA" => "da", "CE" => "do",
      "ES" => "do", "GO" => "de", "MA" => "do", "MT" => "de", "MS" => "de", "MG" => "de",
      "PA" => "do", "PB" => "da", "PR" => "do", "PE" => "de", "PI" => "do", "RJ" => "do",
      "RN" => "do", "RS" => "do", "RO" => "de", "RR" => "de", "SC" => "de", "SP" => "de",
      "SE" => "de", "TO" => "do"
    }.freeze

    def build_ref_linha(args)
      descricao = args[:descricao_servico].to_s.strip
      linha = +"Proposta de serviço para #{descricao}"
      linha << municipio_clause(args[:municipios])
      linha << estado_clause(args[:estado])
      "#{linha.sub(/\.\z/, '')}."
    end

    def municipio_clause(municipios)
      municipios = municipios.to_s.strip
      return "" if municipios.blank?

      partes = municipios.split(/\s*(?:,|;|\/|\se\s)\s*/).reject(&:blank?)
      preposicao = partes.size <= 1 ? "no município de" : "nos municípios de"
      ", #{preposicao} #{municipios}"
    end

    def estado_clause(estado)
      sigla = estado.to_s.strip.upcase
      return "" if sigla.blank?
      return ", no Distrito Federal" if sigla == "DF"

      nome = UF_NOMES[sigla]
      return ", estado #{estado}" if nome.blank?

      ", estado #{UF_ARTIGO.fetch(sigla, 'de')} #{nome}"
    end

    # Padrão da Papyrus: licenciamento da família Prévia/Instalação (LP, LI, RLP, RLI e combinações)
    # tem SEMPRE prazo contratual de 12 meses — pedido do consultor ("sempre estabelecer prazo de
    # doze meses contratuais nestes casos"). Regra determinística: não fica a cargo da IA. Nos
    # demais atos vale o prazo que a IA escreveu a partir do ET/TR.
    LP_LI_FAMILY_ACTS = %w[LP LI RLP RLI LPI].freeze

    # Prazo padrão de 12 meses (2026-09, pedido da Charlene: "quando não houver a informação
    # muito clara, deixar como 12 meses") — não é mais exclusivo da família LP/LI acima: quando o
    # ET/TR não deixa claro o prazo (a IA manda prazo_de_execucao em branco/nil), cai no mesmo
    # padrão de 12 meses, em vez de sair sem nenhum prazo no documento. Continua sendo conta
    # determinística em Ruby, nunca a IA "inventando" um número pra preencher a lacuna.
    def prazo_execucao_value(args)
      return "12 (doze) meses contratuais" if lp_li_family_licensing?

      args[:prazo_de_execucao].presence || "12 (doze) meses contratuais"
    end

    def lp_li_family_licensing?
      (@proposal.license_act_acronyms & LP_LI_FAMILY_ACTS).any?
    end

    # Remove qualquer "[F12]" residual (recursivo — topicos_escopo/produtos/itens_nao_previstos
    # etc. chegam como array) e limpa o espaço duplo que sobra no lugar. Mesmo padrão de citação
    # do chat (Message::CITATION_PATTERN) — reaproveitado aqui só pra DETECTAR e apagar, nunca
    # pra virar link (isso não existe no .docx).
    def strip_citation_codes(value)
      case value
      when String
        value.gsub(Message::CITATION_PATTERN, "").gsub(/[ \t]{2,}/, " ").strip
      when Array
        value.map { |item| strip_citation_codes(item) }
      else
        value
      end
    end

    # Cada item vira um parágrafo/item de lista próprio no modelo (ver expand_into_paragraphs!);
    # lista vazia devolve "" — junto com remove_paragraph_if_blank, isso some o item de lista
    # inteiro, em vez de deixar um "●" sem texto na maioria das propostas (que não tem nada extra).
    def join_lines(items)
      Array(items).map { |item| item.to_s.strip }.compact_blank.join("\n")
    end

    # Os índices são a POSIÇÃO da tabela no modelo, não um id: 0 = sumário de revisões,
    # 1 = produtos, 2 = equipe técnica (linhas de proposal_professionals, ver Proposal#team_rows_
    # for_docx — virou dinâmica em 2026-09), 3 = preço (Quadro N-1, N° | SERVIÇO | PREÇO R$,
    # reintroduzido em 2026-09 — ver Proposal#docx_price_rows), 4 = desembolso (Quadro N-2,
    # N° | MARCO | % | VALOR R$).
    # Mudaram na revisão de 2026-08 do modelo, quando o quadro de preço por linha deixou de
    # existir, e de novo em 2026-09, quando voltou (agora com 1 linha só, o total).

    # A seção "ESCOPO E METODOLOGIA DE EXECUÇÃO DO SERVIÇO" é sempre a 5ª de nível 1 no modelo —
    # a estrutura de seções é fixa, só o conteúdo varia por proposta — por isso o número dos
    # subtópicos pode ser calculado aqui: a IA não tem como saber a posição real da seção no
    # documento renderizado, só o sistema sabe.
    SECAO_ESCOPO_NUMERO = 5

    # Só a metodologia da IA — os "itens não previstos" saíram daqui (2026-09): viraram capítulo
    # independente ("ITENS NÃO PREVISTOS", 7ª seção do modelo), preenchido por
    # #build_itens_nao_previstos no placeholder {{ITENS_NAO_PREVISTOS}}. A frase fixa sobre
    # proposta complementar agora é texto FIXO do modelo, logo abaixo do placeholder.
    def escopo_e_topicos(args)
      [ args[:escopo_e_metodologia], topicos_do_escopo(args) ].compact_blank.join("\n\n")
    end

    # Lista do capítulo "ITENS NÃO PREVISTOS" — um "- item" por linha, com uma frase introdutória
    # só quando há algum item. Vazio devolve "" e o parágrafo do placeholder some
    # (remove_paragraph_if_blank), sobrando no capítulo só a frase fixa do modelo.
    def build_itens_nao_previstos(args)
      itens = Array(args[:itens_nao_previstos]).map { |item| item.to_s.strip }.compact_blank
      return "" if itens.empty?

      ([ "Não estão contemplados nesta proposta os seguintes itens:" ] + itens.map { |item| "- #{item}" }).join("\n")
    end

    # "Título | texto" vira "**5.N TÍTULO**" (negrito — ver ProposalDocxFiller#apply_line!)
    # seguido do texto normal do tópico. Devolve "" quando a IA não usar topicos_escopo (escopo
    # sem divisão temática), então não sobra nada em branco depois da introdução.
    def topicos_do_escopo(args)
      topicos = Array(args[:topicos_escopo]).filter_map do |item|
        titulo, texto = item.to_s.split("|", 2).map(&:strip)
        titulo.presence && texto.presence && [ titulo, texto ]
      end

      topicos.each_with_index.map do |(titulo, texto), index|
        "**#{SECAO_ESCOPO_NUMERO}.#{index + 1} #{titulo.upcase}**\n\n#{texto}"
      end.join("\n\n")
    end

    # "Produto | Formato" vira linha normal; "Fase:" (sem formato) vira linha de agrupamento, do
    # jeito que a Papyrus separa os produtos por fase do licenciamento.
    def build_tables(args, description)
      produtos = Array(args[:produtos]).filter_map do |item|
        nome, formato = item.to_s.split("|", 2).map(&:strip)
        next if nome.blank?

        agrupamento = formato.blank? && nome.end_with?(":")
        [ nome, agrupamento ? "" : formato.presence || "Digital (PDF)" ]
      end

      {
        0 => { rows: @proposal.docx_revision_rows(current_description: description) },
        1 => { rows: produtos },
        # merge_first_column: junta "Diretoria"/"Gestão"/"Execução" numa célula só quando mais de
        # um profissional cai no mesmo setor em linhas consecutivas (2026-09, pedido do consultor
        # — ver ProposalDocxFiller#merge_first_column!).
        2 => { rows: @proposal.team_rows_for_docx, merge_first_column: true },
        3 => { rows: @proposal.docx_price_rows(descricao_fallback: args[:descricao_servico]), auto_number: true },
        4 => { rows: @proposal.docx_payment_schedule_rows, auto_number: true }
      }
    end

    # Não faz broadcast aqui: esta tool call roda DENTRO da transação do with_ai_lock
    # (Conversation#complete_with_lock), então um broadcast daqui chega no navegador ANTES do
    # commit e ele re-renderiza sem o arquivo novo ("às vezes tenho que dar F5"). Quem dispara o
    # refresh é RespondToMessageJob, depois do commit, ao notar que generated_documents cresceu.
    def attach!(bytes, filename, kind, description)
      @proposal.generated_documents.attach(
        io: StringIO.new(bytes),
        filename: filename,
        content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        metadata: { kind: kind, version: @proposal.version, description: description }
      )
    end

    # Sob demanda, não por padrão (2026-09, pedido do consultor): antes, todo cronograma virava
    # também um .xml de MS Project em TODA geração — a maioria das propostas nunca chega a ser
    # importada em nenhum MS Project, então o arquivo saía à toa quase sempre. A IA só marca
    # exportar_cronograma_ms_project quando o consultor pediu no chat ou o ET/TR exige esse
    # formato (ver descrição do parâmetro); ActiveModel::Type::Boolean tolera vir como string
    # ("true"/"false", alguns modelos serializam assim) e trata ausência do parâmetro como false.
    # A tabela do cronograma dentro do próprio .docx nunca depende disto — sai sempre.
    def export_ms_project?(args)
      ActiveModel::Type::Boolean.new.cast(args[:exportar_cronograma_ms_project]) == true
    end

    # 2026-09: substitui o antigo gate por status ("draft" = só técnica). Agora é só o pedido
    # EXPLÍCITO do consultor (ver descrição do parâmetro) — nunca inferido do status da proposta.
    def somente_tecnica?(args)
      ActiveModel::Type::Boolean.new.cast(args[:somente_tecnica]) == true
    end

    # 2026-09: espelho de #somente_tecnica? — mesmo princípio (pedido explícito, nunca inferido).
    def somente_comercial?(args)
      ActiveModel::Type::Boolean.new.cast(args[:somente_comercial]) == true
    end

    # 2026-09, pedido do consultor: antes só o ET/TR (na criação da proposta, ver
    # Proposal#build_with_ai_suggested_team!/#build_base_team!) ou a tela de Precificação/
    # Aprovação (ProposalsController#document_split_params) decidiam o formato — pedir a mudança
    # no CHAT não tinha nenhum efeito. Aceita alguns sinônimos tolerantemente (a IA já recebe a
    # instrução de mandar "separado"/"combinado" na descrição do parâmetro, mas nada garante que
    # ela sempre obedece à risca). Valor não reconhecido (ou parâmetro ausente) não muda nada —
    # nunca levanta erro por causa disso, só ignora silenciosamente.
    DOCUMENT_SPLIT_CHAT_VALUES = {
      "separado" => "separated", "separada" => "separated", "separados" => "separated", "separate" => "separated",
      "combinado" => "combined", "combinada" => "combined", "combinados" => "combined", "único" => "combined",
      "unico" => "combined", "junto" => "combined", "juntos" => "combined", "unificado" => "combined"
    }.freeze

    def apply_document_split_override!(formato_documento)
      return if formato_documento.blank?

      mapped = DOCUMENT_SPLIT_CHAT_VALUES[formato_documento.to_s.strip.downcase]
      @proposal.update!(document_split: mapped) if mapped
    end

    # MSPDI (XML do MS Project) por tipo de cronograma presente — ver ScheduleMspdiExporter/
    # CLAUDE.md seção 8. Só roda quando #export_ms_project? diz sim (ver acima). Sai igual em
    # qualquer status da proposta (não é dado de preço), mesmo critério do cronograma dentro do
    # .docx. Falha aqui (ex.: JRE ausente no servidor) não pode derrubar a geração do .docx
    # inteiro — só fica sem o arquivo extra, logado pra investigar.
    SCHEDULE_UNITS = { "servico" => :week, "implantacao" => :month }.freeze
    SCHEDULE_NAMES = {
      "servico" => "Cronograma do Serviço",
      "implantacao" => "Cronograma de Implantação do Empreendimento"
    }.freeze

    # `failed_types` é preenchido por efeito colateral (nunca por retorno) — o chamador já usa o
    # retorno normal (array de filenames) pra montar `filenames:`/o texto de sucesso; um segundo
    # retorno mudaria os 3 call sites pra desestruturar tupla à toa. Só existe pra
    # `schedule_message` poder avisar o consultor quando algum tipo falhou (antes, a falha só ia
    # pro log — o consultor nunca sabia que o .xml não saiu).
    def attach_schedule_mspdi_files!(schedules, args, description, failed_types)
      schedules.filter_map do |type, payload|
        bytes = ScheduleMspdiExporter.new(
          items: payload[:items], start_date: payload[:start_date], unit: SCHEDULE_UNITS.fetch(type),
          name: "#{SCHEDULE_NAMES.fetch(type)} - #{args[:nome_cliente]}"
        ).call
        next if bytes.blank?

        filename = @proposal.schedule_filename(type)
        @proposal.generated_documents.attach(
          io: StringIO.new(bytes), filename: filename, content_type: "application/xml",
          metadata: { kind: "schedule_mspdi_#{type}", version: @proposal.version, description: description }
        )
        filename
      rescue ScheduleMspdiExporter::JavaHelperError => e
        Rails.logger.error("attach_schedule_mspdi_files! falhou pra tipo #{type} na proposal #{@proposal.id}: #{e.message}")
        failed_types << type
        nil
      end
    end

    def schedule_message(schedule_filenames, defaulted_schedule_types, schedule_background_task, failed_schedule_types = [], team_background_task: nil)
      parts = []
      if team_background_task == :team
        parts << " Estou sugerindo a equipe técnica desta proposta em segundo plano — quando " \
          "terminar, gero uma nova versão sozinho e aviso aqui, sem precisar pedir de novo."
      end
      if schedule_filenames.present?
        parts << " O cronograma também saiu em formato MS Project (#{schedule_filenames.join(', ')}). " \
          "Pra importar: no MS Project, Arquivo > Abrir > Procurar, troque o tipo de arquivo de " \
          "\"Projetos\" pra \"Formato XML (*.xml)\" na caixinha embaixo do nome (senão o arquivo nem " \
          "aparece), selecione o arquivo e escolha \"Como um novo projeto\". Clicar duas vezes no " \
          ".xml não abre no MS Project — tem que ser por Arquivo > Abrir."
      end
      if failed_schedule_types.present?
        nomes = failed_schedule_types.map { |type| SCHEDULE_NAMES.fetch(type) }.join(" e ")
        parts << " Não consegui gerar o arquivo do #{nomes} em formato MS Project agora (o resto do " \
          "documento saiu normal) — se persistir, avise o time de desenvolvimento."
      end
      if defaulted_schedule_types.present?
        nomes = defaulted_schedule_types.map { |type| SCHEDULE_NAMES.fetch(type) }.join(" e ")
        data = Date.current.next_month.beginning_of_month.strftime("%d/%m/%Y")
        parts << " Aviso: o consultor não informou a data de início do #{nomes}, então presumi #{data} " \
          "(início do mês que vem) — se não for essa a data certa, é só falar a data no chat ou " \
          "corrigir na Tela de Precificação e gerar de novo."
      end
      case schedule_background_task
      when :schedule
        parts << " Estou sugerindo o cronograma desta proposta em segundo plano — quando " \
          "terminar, gero uma nova versão sozinho e aviso aqui, sem precisar pedir de novo."
      when :key_points
        parts << " Estou selecionando os principais marcos do cronograma pro infográfico em " \
          "segundo plano — quando terminar, gero uma nova versão sozinho e aviso aqui, sem " \
          "precisar pedir de novo."
      when :schedule_update
        parts << " Estou reconstruindo o cronograma (tabela e infográfico) com a mudança pedida, " \
          "em segundo plano — quando terminar, gero uma nova versão sozinho e aviso aqui, sem " \
          "precisar pedir de novo."
      end
      parts.join
    end

    # Três coisas que a IA prepara em background pro cronograma sair completo/correto, nesta
    # ordem de prioridade:
    #
    # 0. `:schedule_update` — o consultor pediu uma MUDANÇA (param `atualizar_cronograma`, ver
    #    Proposal#regenerate_schedule!): enfileira RegenerateScheduleJob, que APAGA e RECONSTRÓI
    #    o cronograma do zero. Único dos três que NÃO é idempotente por natureza — é uma ação
    #    explícita, checada primeiro porque sobrepõe as checagens de "já existe?" abaixo.
    # 1. `:schedule` — NENHUM item ainda: enfileira SuggestScheduleJob, que MONTA o cronograma
    #    (fases/atividades/durações) e já elege os ≤6 marcos do infográfico no mesmo passo. Cobre
    #    a proposta cuja primeira tentativa (em Conversation#ensure_proposal!) falhou/veio vazia
    #    por faltar informação que só chegou depois (TR, complementar, acervo).
    # 2. `:key_points` — TEM cronograma do serviço, mas os ≤6 marcos do infográfico ainda não
    #    foram eleitos (proposta criada antes desta funcionalidade, ou cronograma montado à mão
    #    na Tela de Precificação): enfileira ElectScheduleKeyPointsJob, que só elege os marcos a
    #    partir do que já existe — nunca mexe nos schedule_items.
    #
    # Idempotente em 1 e 2: (1) só quando não há item nenhum, (2) só quando não há
    # schedule_key_points ainda — nunca reescreve o que o consultor ajustou sem pedido explícito.
    # SEMPRE em background,
    # NUNCA `build_with_ai_suggested_schedule!`/`elect_schedule_key_points!`/`regenerate_schedule!`
    # direto aqui — esta ferramenta roda como tool call DENTRO de Conversation#complete
    # (RespondToMessageJob), e
    # chamar a IA síncrona ali reentraria complete/ask_internally (achado ao vivo conversa 32/
    # proposta 18: a chamada ao Bedrock falhava sozinha, sem exceção pro rescue pegar, e o
    # cronograma ficava vazio pra sempre). Devolve o símbolo do que enfileirou (ou nil), pra
    # #schedule_message avisar o consultor.
    # Tenta de novo enquanto `distance_km` ainda estiver no default (zero) — cobre o caso do KMZ
    # (ou o cruzamento com ibge_municipalities) ainda não ter terminado quando a proposta foi
    # criada (Conversation#ensure_proposal!). Idempotente e síncrono: diferente do cronograma,
    # ProjectPricing#suggest_logistics! é só Ruby + HTTP, nunca IA, então não tem o problema de
    # reentrância que obriga o cronograma a rodar em job de background.
    def ensure_logistics_suggested!
      pricing = @proposal.project_pricing
      pricing.suggest_logistics! if pricing && pricing.distance_km.zero?
    end

    # Achado em produção: gerar a proposta direto pelo chat (`ensure_proposal!(ai_suggestions:
    # false)`, ver Conversation) deixa a equipe só com Diretoria/Coordenação a 0h — parecia "a IA
    # não mapeou a equipe". Enfileira SuggestTeamJob (nunca a IA síncrona aqui, mesmo motivo do
    # cronograma — reentrância de Conversation#complete) só enquanto a equipe estiver nesse estado
    # (Proposal#team_untouched?).
    # Idempotente: nunca reescreve o que já foi sugerido ou ajustado. Devolve `:team` (ou nil),
    # pra #schedule_message avisar o consultor.
    def ensure_team_background_work!
      pricing = @proposal.project_pricing
      return nil unless pricing
      return nil unless @proposal.team_untouched?(pricing)

      SuggestTeamJob.perform_later(@proposal.id)
      :team
    end

    def ensure_schedule_background_work!(args)
      pricing = @proposal.project_pricing
      return nil unless pricing

      # Pedido explícito de MUDANÇA num cronograma que já existe (ver param atualizar_cronograma)
      # tem prioridade sobre as checagens de idempotência abaixo — é a única forma da IA conseguir
      # reconstruir schedule_items depois da 1ª sugestão (achado em produção: conversa 44, ver
      # Proposal#regenerate_schedule!).
      if ActiveModel::Type::Boolean.new.cast(args[:atualizar_cronograma]) == true
        RegenerateScheduleJob.perform_later(@proposal.id)
        return :schedule_update
      end

      unless pricing.schedule_items.exists?
        SuggestScheduleJob.perform_later(@proposal.id)
        return :schedule
      end

      if pricing.schedule_key_points.blank? && pricing.schedule_items.for_type("servico").exists?
        ElectScheduleKeyPointsJob.perform_later(@proposal.id)
        return :key_points
      end

      nil
    end

    # O consultor pode ditar a data de início no CHAT (mesmo padrão de nome_arquivo/
    # docx_filename_override) — a IA só passa o parâmetro quando ele disse algo explicitamente,
    # nunca inventa. Formato livre tolerado (Date.parse aceita "2026-10-15" e várias variações);
    # data ilegível é ignorada em silêncio, não derruba a geração.
    def apply_schedule_start_date_overrides!(args)
      pricing = @proposal.project_pricing
      return unless pricing

      updates = {}
      updates[:schedule_papyrus_start_date] = parsed_date(args[:data_inicio_cronograma_servico])
      updates[:schedule_empreendimento_start_date] = parsed_date(args[:data_inicio_cronograma_implantacao])
      pricing.update!(updates.compact) if updates.compact.present?
    end

    def parsed_date(value)
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue Date::Error, TypeError
      nil
    end

    # Quando existe item de cronograma mas ainda não há data de início (nem já cadastrada, nem
    # dita agora no chat — ver #apply_schedule_start_date_overrides!), presume o INÍCIO DO MÊS QUE
    # VEM em vez de deixar a página de fora do documento em silêncio (CLAUDE.md seção 8). É um
    # padrão determinístico do sistema, não a IA "adivinhando" a partir do contexto — a mesma
    # distinção de sempre (motor de preço/regras determinísticas, nunca a IA, decidindo o que não
    # é conteúdo). Nunca sobrescreve uma data que já existe. Devolve os tipos que foram
    # presumidos, pra avisar o consultor na mensagem de retorno (#schedule_message).
    def default_missing_schedule_dates!
      pricing = @proposal.project_pricing
      return [] unless pricing

      default = Date.current.next_month.beginning_of_month

      ScheduleItem::SCHEDULE_TYPES.select do |type|
        next false unless pricing.schedule_items.any? { |item| item.schedule_type == type }
        next false if schedule_start_date(pricing, type).present?

        pricing.update!(schedule_start_date_column(type) => default)
        true
      end
    end

    def schedule_start_date(pricing, type)
      pricing.public_send(schedule_start_date_column(type))
    end

    def schedule_start_date_column(type)
      type == "servico" ? :schedule_papyrus_start_date : :schedule_empreendimento_start_date
    end
end
