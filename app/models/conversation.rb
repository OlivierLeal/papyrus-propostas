class Conversation < ApplicationRecord
  acts_as_chat
  include LlmMessageOrdering
  include AiResponding

  has_many :knowledge_notes, dependent: :destroy
  # Versões finais revisadas manualmente que o consultor mandou aprender pro acervo RAG (ver
  # LearnFromRevisedProposalTool/HistoricalProposal#approve!) — sem dependent: propositalmente,
  # mesma FK sem ON DELETE já existente antes desta associação existir (nenhuma mudança de
  # comportamento na exclusão de uma conversation).
  has_many :historical_proposals
  # O entendimento estruturado do projeto (o que foi lido, onde, e com que grau de certeza) e as
  # divergências entre documentos — ver ProjectFinding e ProjectConflict.
  has_many :project_findings, dependent: :destroy
  has_many :project_conflicts, dependent: :destroy
  has_many :project_issues, dependent: :destroy
  belongs_to :framing_confirmed_by, class_name: "User", optional: true

  STATUSES = %w[setup processing reviewing pricing completed].freeze

  STATUS_LABELS = {
    "setup" => "Configuração",
    "processing" => "Processando",
    "reviewing" => "Em revisão",
    "pricing" => "Precificação",
    "completed" => "Concluída"
  }.freeze

  # Cor do selo de cada etapa (lista de propostas e cabeçalho da conversa) — uma cor por etapa,
  # pra dar pra separar as propostas de relance. Classes completas aqui (não montadas por
  # interpolação) pro Tailwind enxergar e gerar o CSS. "Precificação" é sólida de propósito: o
  # petróleo da marca em versão suave fica quase igual ao cinza de "Configuração".
  STATUS_BADGE_CLASSES = {
    "setup" => "badge-soft badge-neutral",
    "processing" => "badge-soft badge-info",
    "reviewing" => "badge-soft badge-warning",
    "pricing" => "badge-primary",
    "completed" => "badge-soft badge-success"
  }.freeze

  # Etapas de processamento em background disparadas ao confirmar o setup.
  # "summary" roda depois que as etapas abaixo terminam (done/skipped/failed).
  # "et" é o documento principal (pedido técnico do cliente); "tr" é o guia institucional
  # opcional (ver ProcessEtJob/ProcessTrJob e a nota de terminologia em CLAUDE.md seção 2).
  # "cal" roda ENTRE et e tr, nunca em paralelo com eles: só depois que o ET identifica o(s)
  # município(s) é que dá pra saber o âmbito certo pra pesquisar no CAL (ver ProcessLegalNormsJob),
  # e o resultado dessa pesquisa precisa estar disponível ANTES do TR ser lido, pra a IA já saber o
  # que a legislação exige quando cruzar com o TR institucional. comp_docs e kmz continuam em
  # paralelo com essa cadeia, sem depender dela.
  PROCESSING_STEPS = %w[et cal tr comp_docs kmz].freeze

  PROCESSING_STEP_LABELS = {
    "et" => "Processando ET",
    "cal" => "Pesquisando legislação aplicável (CAL)",
    "tr" => "Processando TR",
    "comp_docs" => "Analisando documentos complementares",
    "kmz" => "Processando KMZ",
    "summary" => "Gerando resumo"
  }.freeze

  # Prompt de sistema (CLAUDE.md seção 9, "Prompt 1"). Mantém a IA restrita ao escopo desta
  # proposta — sem isso ela responde qualquer pergunta fora de contexto e gasta tokens à toa.
  SYSTEM_INSTRUCTIONS = <<~TEXT.freeze
    Você é o assistente de IA integrado ao Papyrus Propostas, usado por um consultor da Papyrus
    Consultoria Ambiental para montar a proposta técnica e comercial desta conversa.

    Seu escopo aqui é estritamente:
    - Analisar o ET (Pedido Técnico do Estudo — o documento em que o CLIENTE explica o que está
      pedindo à Papyrus; é a base do escopo), o TR (Termo de Referência — quando o cliente enviar
      um; documento que vem do ÓRGÃO AMBIENTAL/instituição, com exigências de COMO o estudo deve
      ser executado — metodologia, diagnósticos exigidos, condicionantes; guia a execução do ET,
      não o substitui), o KMZ e os documentos complementares desta proposta.
    - Responder perguntas do consultor sobre o conteúdo desses documentos, o escopo do estudo, a
      equipe técnica sugerida e questões de licenciamento ambiental relacionadas a este projeto.
    - Ajudar a ajustar o resumo da proposta conforme o consultor pedir.
    - Consultar o acervo de projetos ANTERIORES da Papyrus (ferramenta search_historical_archive)
      quando isso ajudar: como a Papyrus já redigiu uma seção parecida, que escopo aplicou num
      tipo de estudo, que equipe montou, que ressalvas fez, ou o que um cliente exigiu num
      projeto semelhante. Use a ferramenta antes de responder "não sei" sobre prática ou padrão
      da Papyrus — e também antes de pedir esclarecimento: se a pergunta é sobre como a Papyrus
      costuma fazer algo, BUSQUE primeiro, mostre o que encontrou e só então peça o contexto que
      faltar. Pedir esclarecimento sem ter consultado o acervo desperdiça uma resposta.
      SEMPRE que usar qualquer informação vinda do acervo, cite a origem no texto
      (cada resultado da ferramenta traz o campo "referencia" pronto para isso) — o consultor
      precisa poder conferir de que projeto veio cada coisa, e informação do acervo sem fonte é
      indistinguível de invenção. Trate valores de propostas antigas como referência histórica,
      nunca como preço desta proposta.

    - Consultar o CAL (ferramenta search_legal_norms, quando disponível) para fundamentar uma
      referência legal específica — qual norma exige um diagnóstico, rege um procedimento, ou
      embasa uma condicionante do ET/TR. Não é pra decidir tipo de licença ou tipo de estudo
      (isso já vem dos achados desta conversa) — é só pra citar a base legal com precisão em vez
      de generalizar. Mesma regra do acervo: cite sempre a "referencia" de cada norma usada.

    - Guardar aprendizado para o futuro (ferramenta remember_for_future_proposals) quando aparecer
      nesta conversa algo que vai se repetir e que hoje só existe aqui: exigência recorrente do
      cliente, decisão de escopo que vale repetir, condicionante do órgão, ou uma correção que o
      consultor fez em você. A ferramenta NÃO guarda na hora — ela propõe, e o consultor aprova
      no card. Seja seletivo: registre no máximo o que for realmente reaproveitável, nunca fato
      pontual deste projeto nem algo que você deduziu sem confirmação. Quando o consultor
      corrigir você sobre um ponto que vale para próximos projetos, ofereça guardar.

    - Citar a origem do que você afirma sobre ESTE projeto. Tudo que foi extraído dos documentos
      desta proposta está listado no bloco [ACHADOS DESTA PROPOSTA], mais abaixo no histórico, cada
      item com um código entre colchetes (ex.: [F12]). Sempre que afirmar algo que veio de um
      desses achados, escreva o código logo depois da afirmação — o sistema transforma o código
      num link que mostra ao consultor o trecho e o documento de onde aquilo saiu. Use SÓ códigos
      que estão na lista: código inventado não vira link nenhum e a afirmação fica sem fonte.
      Não cite código para o que você deduziu ou sugeriu — deixe claro no texto que é dedução sua.

    Qualquer pedido fora desse escopo (perguntas sem relação com este projeto ou com licenciamento
    ambiental, código, receitas, tarefas genéricas ou qualquer assunto alheio a este atendimento):
    recuse em UMA frase curta, sem elaborar, redirecionando o consultor de volta para a proposta.

    NUNCA responda ao consultor no formato `{"achados": [...]}` (ou qualquer JSON cru) — esse
    formato é EXCLUSIVO de instruções internas do sistema (que pedem "Responda APENAS com um
    JSON válido"), que você não vê rotuladas como tal no histórico, mas que aparecem mais acima
    na conversa. Sua resposta pro consultor é SEMPRE texto corrido em português, mesmo quando ele
    colar o texto de um ET/TR direto no chat em vez de anexar como arquivo — nesse caso, leia o
    conteúdo colado, comente o que entendeu em prosa, e sugira reenviar como arquivo anexado se
    fizer sentido (só o upload passa pelo processamento estruturado que gera achados rastreáveis;
    texto colado no chat não gera nenhum achado novo por conta própria).

    Fatos fixos sobre os documentos desta conversa:
    - O KMZ enviado pelo consultor JÁ É a poligonal oficial da área do empreendimento (coordenadas
      reais do imóvel, não um esboço/visualização). Nunca trate isso como informação pendente nem
      peça ao consultor uma "poligonal oficial georreferenciada" separada. Se o ET ou o TR exigir
      que o MAPA FINAL a ser entregue pela Papyrus seja georreferenciado (ex.: SIRGAS 2000), isso é um
      requisito de formato do produto que a Papyrus vai produzir a partir do KMZ — não um dado que
      falta o cliente fornecer antes de começar.

    Você nunca calcula preços, horas ou valores em R$ — isso é feito por um motor determinístico à
    parte. Sua função é só identificar e organizar informações de escopo.

    A mesma regra vale para ESFORÇO no texto do escopo — dias de campo, número de campanhas,
    quantidade de profissionais em campo, número de vistorias ou de reuniões. Esses números já
    existem no sistema (bloco [ESTADO ATUAL DA PROPOSTA], mais abaixo no histórico) e é de lá que
    eles têm que sair, exatamente como estão escritos: não invente, não arredonde e não converta
    unidade (se o sistema diz horas, escreva horas). Número de esforço inventado no texto contradiz
    a planilha que gerou o preço, e é o consultor que descobre isso na frente do cliente. Se o
    sistema ainda não tem aquele número, descreva a atividade sem quantificar ou escreva
    "a definir", em vez de estimar — e gere a proposta assim mesmo. Esta regra é só sobre o TEXTO
    que você escreve nas seções (não estimar um número pra aparecer impresso); ela NUNCA significa
    "não chame generate_proposal_document" ou "peça pro consultor preencher horas/dias de campo
    antes" — equipe com horas zeradas e logística zerada não são motivo pra recusar gerar nada,
    documento ou cronograma (ver item 12 do passo a passo interno).

    Responda sempre em português.
  TEXT

  # Passo a passo interno da Papyrus pra elaborar uma Proposta Técnica (documento cedido pela
  # empresa, atualizado por eles em 2026-08 — mesma numeração do arquivo original). Uso interno
  # da IA — não repita a lista inteira pro consultor a menos que ele peça.
  PROPOSAL_CHECKLIST_INSTRUCTIONS = <<~TEXT.freeze
    Passo a passo interno da Papyrus pra elaboração de uma Proposta Técnica:

    1. Criar a pasta na rede seguindo o padrão de nome da proposta (número + cliente + escopo +
       revisão) — administrativo, feito fora do sistema.
    2. Adicionar a proposta no controle de Propostas da rede (Y:\\6) Controles) — administrativo.
    3. Ler o ET (Pedido Técnico do Estudo — o que o CLIENTE está pedindo) e entender o que está
       sendo pedido; quando houver TR (documento que vem do órgão ambiental/instituição), usá-lo
       como guia de COMO executar — metodologia, diagnósticos exigidos, condicionantes — nunca no
       lugar do ET. Cada empresa apresenta as informações de um jeito diferente. Dúvida sobre o
       CONTEÚDO do ET ou do TR (o que está sendo pedido tecnicamente) é uma questão interna — o
       consultor resolve com Molina ou Pedro, não precisa de e-mail ao cliente.
    4. Se faltar documento necessário ou houver dúvida sobre uma NECESSIDADE do escopo (algo que só
       o cliente sabe responder), isso vai por e-mail via Charlene, pedindo ao cliente.
    5. Enquadrar o empreendimento no órgão ambiental do estado onde fica o projeto. Empreendimentos
       em 2+ estados são federais (IBAMA) — o consultor fala com Molina pra direcionar. Pra outros
       estados, a base já mapeada (CLAUDE.md seção 3) cobre os principais; fora dela, o consultor
       consulta a pasta de licenciamento na rede ou o site do órgão.
    6. Pesquisar propostas anteriores semelhantes em escopo (LP, LI, LA, LO), como base pra
       estruturar esta. Isso se faz com a ferramenta search_historical_archive, que consulta o
       acervo real de projetos passados da Papyrus. Se o resumo apontou projetos semelhantes, use-os.
    7. Confirmar dias de campo e deslocamento com a equipe técnica, se houver trabalho de campo.
    8. Verificar se precisa de orçamento externo de prestadores (fauna, flora, meio físico,
       arqueologia) — flora e socioeconomia normalmente são equipe interna, não costumam precisar
       de orçamento externo.
    9. Se for solicitar orçamento externo, confirmar se o prestador já tem NDA (Termo de
       Confidencialidade) assinado e documentação na Papyrus — sem isso, o consultor pede ao ADM
       pra providenciar com o prestador antes de prosseguir.
    10. Ter a planilha de orçamento completa: dias de campo, deslocamento, valores dos prestadores,
        logística discriminada (sempre com logística detalhada, não um valor fechado).
    11. Consultar escopos e equipes técnicas já usados em serviços parecidos — também pela
        ferramenta search_historical_archive. ANTES de escrever cada seção da proposta (objetivo,
        caracterização, escopo e metodologia, produtos), busque como aquela seção foi redigida
        num projeto semelhante e siga o mesmo padrão de estrutura e linguagem, adaptando o
        conteúdo a este projeto. Nunca copie dados do projeto antigo (área, município, prazo,
        valores) — só a forma. Diga ao consultor qual projeto você usou como referência.
    12. Cronograma (Gantt) do serviço — e, quando o ET/TR pedir explicitamente, de implantação do
        empreendimento — o sistema já sugere e monta sozinho, você não precisa fazer nada demais:
        ao chamar generate_proposal_document ele tenta sugerir automaticamente (se ainda não
        houver nenhum item) e gera junto do .docx um arquivo pronto pra abrir no MS Project. Se o
        consultor disser a data de início no chat (ex.: "o cronograma começa em 15/10"), passe em
        data_inicio_cronograma_servico/data_inicio_cronograma_implantacao; se ele não disser nada
        e não houver data nenhuma cadastrada, o sistema mesmo presume o início do mês que vem e
        avisa disso na resposta — nunca bloqueia a geração por causa do cronograma. Isso vale
        MESMO se a equipe ainda estiver com horas zeradas (0h) e a logística com 0 dias de campo/0
        km: o sistema sugere equipe (template ou IA) e logística (distância/combustível) sozinho a
        cada chamada — não é motivo pra você recusar gerar o documento nem pra escrever uma
        explicação pro consultor preencher esses campos antes de tentar de novo. Sempre chame a
        ferramenta; se algo específico ainda não puder ser calculado, é ELA quem avisa isso na
        própria mensagem de retorno (nunca invente esse aviso por conta própria).
    13. Enviar para Sara ou Charlene revisar — acontece depois de gerado o rascunho, é lembrete pro
        consultor, nunca bloqueia a geração.

    A proposta técnica e a comercial NÃO têm mais bloqueios diferentes por STATUS (2026-09,
    pedido do consultor: "quando pedir pra gerar, ele já pensar na parte comercial") — a
    ferramenta generate_proposal_document gera o documento COMPLETO (comercial, ou o combinado
    técnica+comercial) por padrão, mesmo com a proposta ainda em "draft" (preço não revisado); ela
    mesma avisa na mensagem de retorno quando isso acontece, pra você repassar ao consultor.
    "Draft" deixou de ser motivo pra você recusar chamar a ferramenta ou pra restringir o que ela
    gera — só o pedido EXPLÍCITO do consultor faz isso (ver `somente_tecnica` abaixo).

    Verifique os itens 3, 5, 6 e 11 antes de chamar a ferramenta, em QUALQUER pedido — e mesmo
    esses só bloqueiam de verdade se forem IMPOSSÍVEIS de resolver com o que você já tem (ex.:
    item 3 bloqueia só se não houver ET nenhum anexado — a AUSÊNCIA de TR nunca bloqueia, ele é
    opcional; item 5 bloqueia só se você não souber nem dizer se o órgão é estadual ou federal).
    Os itens 7, 8 e 10 (dias de campo, orçamento externo, planilha de preço) são coisa de
    PRECIFICAÇÃO — "verificar" aqui é só CONFERIR/LEMBRAR o consultor deles (ex.: "ainda não há
    custo externo de fauna lançado, considere lançar antes de aprovar o preço"), NUNCA bloqueiam a
    geração nem fazem você recusar chamar a ferramenta, em nenhum dos dois lados. Equipe com 0h ou
    logística zerada também não bloqueiam — o preço sai calculado com o que já existe (mesmo que
    0), e o consultor ajusta na Tela de Precificação depois. DETALHE regulatório incerto (data
    exata de perímetro urbano, percentual de vegetação a manter, necessidade de inventário
    florestal, documentação geológica pendente, etc.) TAMBÉM não bloqueia — escreva a
    condicionante no texto da seção cabível cobrindo os cenários possíveis, ou como "A confirmar
    com o cliente" (mesma regra que já vale pra nome/CNPJ incerto), e gere a proposta assim mesmo.
    O consultor prefere um rascunho pra revisar e ajustar no chat depois a ficar esperando um menu
    de opções antes de ver qualquer coisa — não pergunte "Opção A/B/C", só gere. Se 3, 5, 6 e 11
    estiverem minimamente resolvidos, chame a ferramenta.

    EXCEÇÃO (2026-09-30): o que MUDA escopo, quantitativo, equipe, prazo ou preço e só o consultor
    ou o cliente sabem responder (ex.: "as bacias X e Y do cronograma estão no escopo?", "as 2.994
    diárias da planilha batem com a escala 14×14?") não vai só no texto: registre com
    register_pending_issue. Pendência aberta e divergência sem decisão travam a geração — é o
    sistema que trava, não você; o estado da proposta mostra o que está aberto a cada turno.
    Dado de cadastro (CNPJ, contato, e-mail), detalhe regulatório menor e tudo o que o sistema
    calcula (equipe, horas, logística, cronograma, preço) continuam NÃO sendo pendência.

    Só marque `somente_tecnica: true` quando o consultor pedir EXPLICITAMENTE só a parte técnica
    (ex.: "gera só a técnica por enquanto", "ainda não quero mostrar preço") — nunca por conta
    própria, nunca só porque o status é "draft". Só marque `somente_comercial: true` quando pedir
    EXPLICITAMENTE só a parte comercial (ex.: "manda só a comercial", "só o documento de preço") —
    mesma regra, nunca os dois juntos. Sem nenhum dos dois, sempre gera o documento completo.

    `formato_documento` (2026-09) é só pra quando o consultor pede, PELO CHAT, pra trocar entre
    documento único e documentos separados dali pra frente (ex.: "separa em dois arquivos",
    "pode juntar tudo num só"). NÃO use isso só porque o ET/TR pede documentos separados — isso já
    é decidido sozinho ao criar a proposta, lendo o ET/TR; sem esse pedido explícito do consultor
    no chat, nunca envie este parâmetro.

    Os itens 1, 2, 4, 9 e 13 são administrativos e internos da Papyrus (pasta na rede, controle de
    propostas, e-mail ao cliente, NDA de prestador, revisão com Sara/Charlene) — apenas lembre o
    consultor deles quando fizer sentido, nunca impeça a geração por causa deles.

    Chame a ferramenta generate_proposal_document com o texto de cada seção baseado em tudo que já
    foi lido nesta conversa (ET, TR quando houver, documentos complementares, propostas anteriores
    semelhantes).
    Nunca invente nome de cliente, CNPJ ou contato que você não tenha visto em algum documento —
    escreva "A confirmar" nesses campos em vez de adivinhar. Preço, equipe e formato do documento
    (único ou separado) a ferramenta já busca sozinha do sistema.

    O modelo já traz fixas as obrigações padrão da CONTRATANTE (cliente) e da PAPYRUS (a prestadora
    — sempre "Papyrus"/"PAPYRUS" no texto, nunca "CONTRATADA") — não repita nelas. Se o ET ou o TR exigir algo ESPECÍFICO desta proposta além disso (ex.: o
    cliente exige escolta armada pra vistoria, o órgão exige relatório mensal de acompanhamento),
    identifique de que parte é a obrigação e passe em obrigacoes_contratante_adicionais ou
    obrigacoes_papyrus_adicionais. Não invente nem generalize uma exigência específica de outro
    projeto — só o que o documento desta proposta realmente pedir.
  TEXT

  belongs_to :user
  # Não é escolhido no setup — a IA identifica lendo o ET (ver #assign_study_type_from_findings!,
  # chamado por ProcessEtJob e, quando houver TR e o ET não tiver definido antes, por ProcessTrJob),
  # restrito ao menu real de StudyType. Fica nil até isso acontecer (ou se não houver ET nem TR).
  # Uma proposta pode exigir vários estudos ao mesmo tempo (ex.: EIA-RIMA + Relatório Técnico
  # complementar), ou nenhum — só assessoria/monitoramento contínuo ("Acompanhamento", mais um
  # StudyType cadastrado como qualquer outro, não um caso especial no código). Por isso 2026-09:
  # deixou de ser `belongs_to :study_type` (FK única) — ver `conversation_study_types`.
  has_many :conversation_study_types, dependent: :destroy
  has_many :study_types, through: :conversation_study_types
  has_one :geospatial_result, dependent: :destroy
  has_one :proposal, dependent: :destroy

  validates :client_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  # Refresca a página inteira (só o que mudou, via morph — ver layout) sempre que a conversa é
  # atualizada, ex.: status "processing" -> "reviewing". Cobre updates via `update!` normal; o
  # merge atômico em mark_step! usa update_all (bypassa callback), por isso chama na mão lá embaixo.
  broadcasts_refreshes

  def status_label
    STATUS_LABELS.fetch(status, status)
  end

  def status_badge_class
    STATUS_BADGE_CLASSES.fetch(status, "badge-ghost")
  end

  # "EIA-RIMA, Relatório Técnico" (vários), "Acompanhamento" (um só, cadastrado como qualquer
  # outro tipo), ou o aviso de que nenhum foi identificado ainda — nunca mais um bloqueio (ver
  # CLAUDE.md seção 13, "proposta pode ter N tipos de estudo"). Usado nas telas no lugar do antigo
  # `study_type&.name`.
  def study_types_label
    # `.map(&:name).sort` (Ruby), nunca `.order(:name).pluck(:name)` (SQL) — isso dispararia uma
    # consulta NOVA mesmo quando `study_types` já veio via `includes` (Conversation.search),
    # jogando fora o eager load (Bullet acusa "unused eager loading" nesse caso).
    study_types.map(&:name).sort.join(", ").presence || "Tipo de estudo: aguardando identificação da IA"
  end

  # Custo de IA acumulado NESTA conversa inteira (ET/TR, todos os turnos de chat, sugestões de
  # equipe/cronograma em background) — soma de `Message#cost` (nativo do ruby_llm, ver CLAUDE.md
  # seção 5 "IA nunca faz conta de dinheiro": isto é só leitura do que a própria gem já calcula a
  # partir de tokens × pricing de `models`, nunca um cálculo próprio). Sempre em USD — a gem não
  # faz conversão de câmbio, e o projeto não tem uma fonte de câmbio própria; exibir como "US$",
  # nunca fingir R$. `nil` quando falta preço cadastrado pra algum modelo/token usado (ex.:
  # `bin/rails ruby_llm:load_models` não rodou nesta base ainda) — mostrar "—" nesse caso, nunca
  # 0,00, que sugeriria "gratuito" em vez de "não sei calcular".
  def ai_cost_usd
    cost.total
  end

  # Busca na tela de Propostas por cliente, código (ex.: "PTC26098") ou ano — um campo só, porque
  # o código já embute o ano (ver Proposal#docx_numero_proposta) e a maioria digita só um dos três
  # de cada vez. Filtra em Ruby, não em SQL: código não é coluna nenhuma, é calculado a partir de
  # created_at + id, então não dá pra fazer WHERE nele — aceitável na escala deste app (poucos
  # usuários, sem paginação ainda). `includes(:proposal)` no chamador evita N+1 ao calcular o
  # código de cada conversa.
  # `messages: :model` entra pro card de custo de IA na Tela de Propostas (#ai_cost_usd) não
  # disparar N+1 — cada Message#cost lê a `model_association` (pricing) pra calcular o valor.
  def self.search(query)
    normalized = query.to_s.strip.downcase
    return order(created_at: :desc).includes(:user, :study_types, :proposal, messages: :model) if normalized.blank?

    # Acha os ids em duas passadas: a 1ª só decide quem bate (com o mínimo de includes pra
    # calcular o código sem N+1), a 2ª carrega o que a tela realmente precisa — SÓ para os ids que
    # sobraram. Um includes só, aplicado antes do filtro, dispara "eager load não usado" no Bullet
    # sempre que a busca não bate com nada (nenhuma associação chega a ser lida da lista vazia).
    ids = includes(:proposal).select { |conversation| conversation.matches_search?(normalized) }.map(&:id)
    return none if ids.empty?

    where(id: ids).order(created_at: :desc).includes(:user, :study_types, :proposal, messages: :model)
  end

  def matches_search?(normalized_query)
    return true if client_name.to_s.downcase.include?(normalized_query)
    return true if created_at.strftime("%Y").include?(normalized_query) || created_at.strftime("%y") == normalized_query
    return true if proposal.present? && proposal.docx_numero_proposta.downcase.include?(normalized_query)

    false
  end

  # Cria a proposta (e a equipe sugerida pela IA) sob demanda — chamado tanto pelo botão "Avançar
  # para Precificação" quanto pelo chat, na primeira vez que o consultor pede pra gerar algo.
  # Antes disso só existia via clique no botão, e a IA acabava respondendo "clique em Avançar pra
  # Precificação" pra QUALQUER pedido de geração, mesmo só-técnica — visto na prática confundindo
  # o consultor ("não quero avançar pra preço ainda, quero só a técnica"). Continua sendo a mesma
  # Proposal/ProjectPricing de sempre por baixo (a técnica em draft já usa isso — ver
  # GenerateProposalDocumentTool); só o gatilho de criação deixou de exigir a tela.
  # Retorna nil (sem criar nada) se faltar pré-requisito real (revisão concluída, tipo de estudo
  # identificado) — quem chama decide o que fazer com isso.
  # Marcador do achado que registra "a IA identificou um tipo de estudo que não existe no
  # cadastro" — usado pra não duplicar o aviso quando ET e TR passam por aqui na mesma conversa.
  STUDY_TYPE_OUT_OF_CATALOG = "tipo de estudo fora do cadastro".freeze

  # Associa os tipos de estudo a partir dos achados já extraídos (ET, e TR como reforço) — uma
  # proposta pode precisar de VÁRIOS estudos ao mesmo tempo, ou de nenhum (só acompanhamento,
  # também um StudyType cadastrado como qualquer outro). ADITIVO, não sobrescreve: o TR pode
  # trazer um achado de tipo_estudo que o ET não mencionou, e os dois devem ficar associados —
  # por isso não tem mais o "return if já definido" que a versão singular tinha (2026-09).
  #
  # Antes (versão singular) isto vivia duplicado em ProcessEtJob/ProcessTrJob e era um
  # `find_by(code:)` seco: código que não batesse com nenhum cadastro não fazia NADA — nem
  # gravava, nem avisava ninguém. A conversa 31 (produção, VSZ Energy) travou exatamente aí: a IA
  # respondeu "eai" (Estudo Ambiental Intermediário), que a Papyrus nunca cadastrou, study_type
  # ficou nil, e a partir daí generate_proposal_document recusou gerar a proposta pra sempre — sem
  # que o consultor nem a IA tivessem como saber o motivo.
  #
  # O casamento tolera a IA devolver o nome no lugar do código (StudyType.match_ai_value), e o que
  # não casa vira um achado visível — mesma regra da sugestão de equipe fora do cadastro
  # (Proposal#flag_out_of_catalog): ou falta cadastro, ou a IA inventou, e as duas coisas são
  # informação pro consultor (não bloqueia mais nada, ver flag_study_type_out_of_catalog).
  # A NORMA vence o pedido do cliente (2026-09-30, Sara: "a gente sempre busca seguir primeiro via
  # requisito normativo"; consultor: "o cliente pode não ter a informação ou estar desatualizado") —
  # ver #framing_values. Roda depois do ET, do CAL e do TR: o ET chega primeiro, e o que ele pediu
  # é TROCADO pelo que a norma exige assim que o CAL termina. Tipo marcado à mão no painel (que não
  # veio de achado nenhum) fica.
  def assign_study_types_from_findings!
    values = framing_values("tipo_estudo")
    out_of_catalog = values.reject { |value| StudyType.match_ai_value(value) }
    wanted = values.filter_map { |value| StudyType.match_ai_value(value) }.uniq
    from_findings = project_findings.active.where(field: "tipo_estudo").pluck(:value).filter_map { |value| StudyType.match_ai_value(value) }

    stale = study_types.to_a & (from_findings - wanted)
    self.study_types -= stale if stale.any?
    wanted.each { |type| study_types << type unless study_types.include?(type) }

    flag_study_type_out_of_catalog(out_of_catalog)
  end

  # Trava de confirmação do enquadramento (2026-09-29, relato da Sara: "estou lendo o resumo no
  # automático e já peço pra gerar" — o sistema tinha enquadrado diferente da Papyrus, e o escopo
  # inteiro saiu no enquadramento errado). Antes de precificar ou gerar o 1º documento, um consultor
  # confirma licença e estudo(s) no painel. Propostas que já têm documento gerado não travam — já
  # passaram desse ponto antes da trava existir.
  def framing_confirmation_required?
    framing_confirmed_at.nil? && !proposal&.generated_documents&.attached?
  end

  # O que TRAVA a geração da proposta (2026-09-30, conversa 65: o consultor pulava os
  # questionamentos e pedia pra gerar direto): divergência sem decisão e pendência sem resposta.
  # Cada uma se libera no próprio card — decidindo/respondendo, ou "seguir sem" com motivo.
  def generation_blockers
    project_conflicts.open.order(:id).to_a + project_issues.open.order(:id).to_a
  end

  def generation_blockers_text
    blockers = generation_blockers
    return nil if blockers.empty?

    lines = blockers.map do |blocker|
      blocker.is_a?(ProjectConflict) ? "- Divergência (#{blocker.field_label}): #{blocker.summary}" : "- Pendência: #{blocker.question}"
    end
    "Não gerei: há #{blockers.size} ponto(s) sem resposta que mudam escopo/preço:\n#{lines.join("\n")}\n" \
      "Apresente cada um ao consultor. Ele responde no card de cada ponto no chat (ou aqui no chat, e aí " \
      "você registra com answer_pending_issue), ou libera com \"Seguir sem resposta\"/\"Seguir sem decidir\" " \
      "escrevendo o motivo. Não chame generate_proposal_document de novo até não restar nenhum."
  end

  # Divergência lei × pedido ainda sem decisão: confirmar antes disso seria confirmar sem escolher.
  def open_legal_framing_conflicts
    project_conflicts.open.where(field: ProjectFinding::FRAMING_FIELDS)
      .where(id: ProjectConflictFinding.joins(:project_finding).where(project_findings: { source_kind: "cal" }).select(:project_conflict_id))
      .to_a
  end

  def confirm_framing!(user)
    return false if open_legal_framing_conflicts.any?

    update!(framing_confirmed_at: Time.current, framing_confirmed_by: user)
  end

  FRAMING_SHORT_LABELS = { "enquadramento_legal" => "Enquadramento", "tipo_licenca" => "Licença", "tipo_estudo" => "Estudo" }.freeze

  # O que o painel mostra pra confirmar: o que foi pedido (ET/TR/consultor) e o que a lei diz (CAL).
  def framing_overview
    findings = project_findings.active.where(field: %w[tipo_licenca enquadramento_legal tipo_estudo]).order(:id)
    requested, legal = findings.partition { |finding| finding.source_kind != "cal" }
    {
      licenses: requested.select { |f| f.field == "tipo_licenca" }.map(&:value).uniq,
      legal: legal.map { |f| [ FRAMING_SHORT_LABELS.fetch(f.field, f.field_label), f.field == "tipo_estudo" ? (StudyType.match_ai_value(f.value)&.name || f.value) : f.value ] }
    }
  end

  # Qual fonte vale pra licença/estudo desta proposta: decisão do consultor > norma (CAL) > o que os
  # documentos do cliente pedem (ET/TR/complementar). Sem enquadramento pela norma (CAL não rodou ou
  # não concluiu), vale o pedido — e o resumo avisa que não foi conferido.
  def framing_values(field)
    findings = project_findings.active.where(field: field).to_a
    chosen = findings.select { |f| f.source_kind == "consultor" }.presence ||
      findings.select { |f| f.source_kind == "cal" }.presence || findings
    chosen.map(&:value).uniq
  end

  # Decisão do consultor numa divergência de tipo de estudo: sai o que foi descartado, entra o
  # escolhido. Mexe só nos tipos que casam com os valores divergentes — um estudo que o consultor
  # marcou à mão por outro motivo continua.
  def replace_study_types!(discarded_values, chosen_value)
    chosen = StudyType.match_ai_value(chosen_value)
    discarded = discarded_values.filter_map { |value| StudyType.match_ai_value(value) } - [ chosen ]
    self.study_types -= discarded if discarded.any?
    study_types << chosen if chosen && !study_types.include?(chosen)
  end

  # ai_suggestions: false é usado por GenerateProposalDocumentTool (chamada pelo chat) — essa
  # ferramenta só é chamada como tool call DENTRO de Conversation#complete (RespondToMessageJob),
  # e as duas sugestões da IA daqui (equipe, cronograma) chamam ask_internally/complete de novo
  # — REENTRANTE, quebra a chamada de verdade pro Bedrock em produção (achado ao vivo, conversas
  # 32/33/34: "tool_use ids were found without tool_result blocks", e o turno inteiro falhava
  # depois, "toolResult blocks... exceeds toolUse blocks", sem o consultor ver a resposta da IA
  # nem o arquivo gerado aparecer no chat, mesmo quando o .docx saía certo por trás). Com
  # ai_suggestions: false, a equipe nasce mínima (`build_base_team!`, só Diretoria/Coordenação,
  # sem IA) e o cronograma fica de fora — GenerateProposalDocumentTool (chamado logo depois)
  # enfileira a sugestão de equipe e de cronograma em background sozinho. Quem chama pelo
  # controller (`ProposalsController`, botão "Avançar para Precificação", fora de qualquer
  # `complete()` em andamento) continua com o padrão `true` — ali é seguro, e o consultor espera
  # ver a equipe já sugerida pela IA ao abrir a Tela de Precificação.
  def ensure_proposal!(ai_suggestions: true)
    # Recarrega antes de checar: quem chama isso pelo chat (RespondToMessageJob) carregou este
    # Conversation no início do job, e a resposta da IA pode levar dezenas de segundos — achado na
    # prática (época em que `study_type` ainda era o gate, antes de 2026-09): o consultor mudou
    # algo pela tela ENQUANTO o job já estava rodando com o objeto antigo em memória (gravado no
    # banco às 14:22:03, mas o objeto em memória do job, carregado às 14:21:58, só via a chamada
    # da ferramenta às 14:22:24 — sem reload, o valor continuava velho pro objeto, mesmo já
    # atualizado no banco havia 21s). `status` é o único gate hoje, mas a mesma corrida vale pra
    # ele.
    reload
    return proposal if proposal.present?
    return nil unless status == "reviewing"

    new_proposal = create_proposal!(status: "draft")
    if ai_suggestions
      new_proposal.build_with_ai_suggested_team!
      new_proposal.build_with_ai_suggested_schedule!
    else
      new_proposal.build_base_team!
    end
    # Só Ruby + HTTP (Logistics::DestinationResolver/MapboxDirections), nunca IA — sem o problema
    # de reentrância de #complete que faz equipe/cronograma precisarem de rescue próprio/job em
    # background (CLAUDE.md seção 5), mas ganha o mesmo rescue interno por segurança: uma falha
    # de rede aqui nunca deve impedir a proposta de ser criada.
    new_proposal.project_pricing&.suggest_logistics!
    update!(status: "pricing")
    new_proposal
  end

  def apply_system_instructions!
    with_instructions(SYSTEM_INSTRUCTIONS)
    with_instructions(PROPOSAL_CHECKLIST_INSTRUCTIONS, append: true)
    messages.where(role: "system").find_each { |message| message.update!(internal: true) }
    mark_system_instructions_cacheable!
  end

  # 2026-09, otimização de custo: SYSTEM_INSTRUCTIONS + PROPOSAL_CHECKLIST_INSTRUCTIONS somados dão
  # ~3.800 tokens, e são reenviados INTEIROS em TODA chamada de IA desta conversa — não só o turno
  # de chat: `ask_internally` (ProcessEtJob, ProcessTrJob, SuggestTeamJob, SuggestScheduleJob,
  # ElectScheduleKeyPointsJob, RegenerateScheduleJob, GenerateSummaryJob, ProcessLegalNormsJob...)
  # e `complete_with_lock` sempre passam por `ChatMethods#to_llm`, que reconstrói o chat inteiro DO
  # ZERO a partir do banco a cada chamada (`@chat.reset_messages!` + replay de toda `messages_
  # association`) — o prompt de sistema nunca é "lembrado" de uma chamada pra outra, é sempre
  # reprocessado. Uma única proposta gera de 4 a mais chamadas em sequência (turno principal +
  # equipe + cronograma + marcos do infográfico, seção 8), cada uma pagando os ~3.800 tokens de
  # novo — sem contar todo o resto da vida da conversa (chat, ET/TR, buscas legais).
  #
  # Marca a ÚLTIMA mensagem "system" (a que fecha PROPOSAL_CHECKLIST_INSTRUCTIONS) com um
  # `cachePoint` do Bedrock Converse API — tudo ANTES desse marcador no array `system` do request
  # (as duas mensagens juntas, `order_messages_for_llm` sempre concatena todo `role: "system"`
  # primeiro) fica cacheado do lado da AWS por alguns minutos: chamadas seguintes da MESMA
  # conversa dentro desse intervalo pagam ~10% do preço normal por esses tokens em vez de 100%
  # (a MapboxDirections dos preços de cache é da própria AWS, não deste código — só estamos
  # marcando o que É cacheável, nunca calculando o desconto, mesmo princípio de "IA/infra nunca
  # calcula preço" da seção 1, aplicado aqui a custo de infraestrutura em vez de preço ao cliente).
  #
  # Só UM cachePoint, sempre no mesmo lugar fixo (fim do prompt de sistema, que nunca muda depois
  # de criado — ver comentário de PROPOSAL_CHECKLIST_INSTRUCTIONS/item 12 sobre isso não ser
  # recalculado). Deliberadamente NÃO se estende esse marcador pro resto do histórico (que cresce
  # a cada turno) — o Converse API tem um limite baixo de cache points por request (poucas
  # unidades), e um marcador por mensagem estouraria esse limite em qualquer conversa
  # moderadamente longa (a conversa de teste usada nesta sessão já tem 59 mensagens). Cache do
  # meio do histórico fica pra uma rodada futura, com mais cuidado nesse limite.
  #
  # NUNCA passar um `RubyLLM::Content::Raw` direto pra `with_instructions`: `ChatMethods#
  # persist_system_instruction` grava a instrução direto na coluna `content` (texto puro, via
  # `create!(role: :system, content: instructions)`), sem passar por `prepare_content_for_storage`
  # — um objeto ali viraria a STRING da inspeção do objeto Ruby ("#<RubyLLM::Content::Raw...>"),
  # persistida como se fosse o prompt de verdade. Por isso a mensagem nasce normal (texto puro,
  # via `with_instructions` como sempre) e só DEPOIS de já existir é que `content_raw` é setado à
  # mão — `Message#extract_content` prioriza `content_raw` sobre `content` quando presente (ver
  # ruby_llm/active_record/message_methods.rb), então toda leitura futura (`to_llm`) passa a usar
  # o array com o cachePoint, sem precisar tocar em mais nada.
  def mark_system_instructions_cacheable!
    last_system_message = messages.where(role: "system").order(:created_at, :id).last
    return unless last_system_message

    last_system_message.update!(
      content_raw: [ { text: last_system_message.content }, { cachePoint: { type: "default" } } ]
    )

    # `with_instructions` (chamado logo acima, ver apply_system_instructions!) já carregou/cacheou
    # a associação `messages` no processo do REQUEST que cria a conversa (ChatMethods#to_llm faz
    # `messages_association.to_a`) — sem resetar, um `#to_llm` chamado NO MESMO objeto Ruby (ex.:
    # um teste, ou um chamador futuro que não recarrega a conversa do banco) reusaria essa cópia em
    # memória, de ANTES deste `update!`, e o cachePoint pareceria não ter feito efeito nenhum. Todo
    # chamador real (ask_internally/complete_with_lock rodando num job/request separado) já parte
    # de um `Conversation.find` fresco e nunca sofreria isso — este reset é só pra não depender
    # dessa garantia implícita.
    messages.reset
  end

  PROPOSAL_STATE_MARKER = "[ESTADO ATUAL DA PROPOSTA]".freeze

  # A IA só enxerga o que está no histórico do chat — os números da Tela de Precificação (que o
  # consultor edita direto, fora do chat) nunca chegam até ela por conta própria. Sem isso, ao
  # pedir "gera a proposta" ela acha que nada foi definido e trava à toa. Chamado antes de cada
  # complete (ver RespondToMessageJob); apaga a versão anterior e recria, então nunca acumula nem
  # fica desatualizado.
  #
  # Roda mesmo sem proposal (visto na prática: sem isso, quando o consultor pede pra gerar antes
  # de clicar "Avançar para Precificação" — GenerateProposalDocumentTool nem existe nesse ponto,
  # ver RespondToMessageJob — a IA não tem como saber disso e inventa que chamou a ferramenta e
  # que "faltam confirmações do cliente", quando na verdade a proposta simplesmente não existe
  # ainda no sistema).
  def refresh_proposal_state_snapshot!
    messages.where(role: "user", internal: true).where("content LIKE ?", "#{PROPOSAL_STATE_MARKER}%").destroy_all
    text = [ proposal.present? ? proposal_state_text : no_proposal_state_text,
             findings_snapshot_text, legal_framing_snapshot_text, conflicts_snapshot_text,
             issues_snapshot_text, framing_gate_snapshot_text ].compact_blank.join("\n")
    snapshot = create_user_message(text)
    snapshot.update!(internal: true)
  end

  # Só mensagens internal: false — o ruby_llm, ao enviar um anexo pra IA via `with:` em
  # ask_internally, persiste uma cópia do attachment na própria mensagem de instrução (internal:
  # true) que carrega o prompt. Sem esse filtro, cada chamada a ask_internally(with: anexo) faz
  # esse anexo "duplicar" nesta lista — ET com 2 arquivos virava 4 depois do primeiro
  # processamento, por exemplo.
  def attachments_of_kind(kind)
    messages.where(internal: false).flat_map(&:attachments).select { |attachment| attachment.blob.metadata["kind"] == kind.to_s }
  end

  # .last, não .first: só existe um chamador hoje (ProcessKmzJob, kind "kmz"), e desde que o KMZ
  # passou a poder chegar a qualquer momento da conversa (não só no setup, ver
  # MessagesController#create), um consultor pode enviar um KMZ substituto depois — o mais RECENTE
  # é o que vale, igual "só a mensagem de usuário mais recente reenvia o anexo bruto pra IA" em
  # Message#stale_for_llm?.
  def attachment_of_kind(kind)
    attachments_of_kind(kind).last
  end

  def processing_step_status(step)
    processing_steps[step.to_s] || "pending"
  end

  def processing_step_label(step)
    PROCESSING_STEP_LABELS.fetch(step.to_s, step.to_s)
  end

  # Descritor do SERVIÇO desta proposta para busca semântica no acervo (resumo, precedentes de
  # valor/equipe, sugestão de equipe). Saiu de GenerateSummaryJob em 2026-09-27 pra ter UM formato
  # só — o mesmo usado pra montar o descritor de cada JobPrecedent (Rag::PrecedentExtractor): o
  # formato da consulta pesa na similaridade (CLAUDE.md seção 11.1, "Calibragem").
  SEARCH_FIELDS = {
    "tipo_licenca" => 120,
    "tipo_estudo" => 160,
    "orgao_ambiental" => 60,
    "municipios" => 120,
    "empreendimento" => 300,
    "diagnosticos" => 300,
    "condicionantes" => 500,
    "ressalvas" => 400
  }.freeze

  # O campo "outro" (onde cai o que não coube no menu, inclusive o tipo do documento
  # complementar) fica FORA da consulta de propósito: é ali que aparece a carta de
  # encaminhamento ("Encaminhamento via Fulana da solicitação de Beltrano..."), exatamente o
  # vocabulário que puxava a recuperação para a capa das propostas antigas.

  def service_descriptor
    fields = project_findings.active.where(field: SEARCH_FIELDS.keys)
      .group_by(&:field)
      .transform_values { |findings| findings.map(&:value).compact_blank.uniq }
    # O código do tipo de estudo ("EIA-RIMA") diz menos que o nome cadastrado na hora de casar
    # com o texto de propostas antigas. Uma proposta pode ter N tipos (ou nenhum — ver
    # CLAUDE.md seção 13) — os nomes entram todos, junto com o resto dos campos de lista.
    fields["tipo_estudo"] = study_types.pluck(:name) if study_types.any?

    SEARCH_FIELDS.filter_map do |field, budget|
      value = Array(fields[field]).map(&:to_s).compact_blank.join("; ")
      "#{field.tr('_', ' ')}: #{value.truncate(budget)}" if value.present?
    end.join("\n")
  end

  # Manda uma pergunta pra IA sem expor a instrução (prompt de sistema do job/controller) na
  # conversa que o consultor vê — só a resposta da IA aparece na tela de revisão/chat.
  # hide_response: true também esconde a resposta da IA do chat (ex.: extrações em JSON que não
  # são pra consultor ler) — por padrão só a instrução fica escondida, porque GenerateSummaryJob
  # depende de ask_internally pra gerar o resumo que o consultor DEVE ver na tela de revisão.
  #
  # with_ai_lock: os jobs de processamento do setup (ET/TR/KMZ/complementares) rodam de propósito
  # em paralelo (config/queue.yml tem 3 threads de worker) — mas ProcessEtJob, ProcessTrJob e
  # ProcessCompDocsJob chamam ask_internally na MESMA conversa ao mesmo tempo. Sem essa trava, duas
  # chamadas concorrentes disputam "a última mensagem do assistente" (linha abaixo, e também em
  # #assign_study_types_from_findings!, chamado por ProcessEtJob/ProcessTrJob), e uma rouba a
  # resposta da outra — visto na prática numa
  # conversa real: a extração estruturada do ET sumiu (perdida pra uma resposta duplicada dos
  # complementares) e o tipo de estudo nunca foi identificado. pg_advisory_xact_lock serializa só
  # as chamadas da MESMA conversa (id como chave) — outras conversas continuam livres pra rodar em
  # paralelo — e libera sozinho quando a transação termina, sem precisar de unlock manual.
  def ask_internally(prompt, with: nil, hide_response: false)
    with_ai_lock do
      # Registra a ferramenta do CAL só quando o histórico desta conversa JÁ tem uso de alguma
      # tool (ver ProcessLegalNormsJob) — achado na prática: a partir daí o histórico passa a ter
      # blocos toolUse/toolResult, e o Bedrock recusa reenviar esse histórico numa chamada futura
      # que não declare toolConfig (erro "The toolConfig field must be defined when using toolUse
      # and toolResult content blocks", mesmo sem nenhuma tool call nova). Não registra
      # incondicionalmente: abriria a ferramenta pra chamadas que esperam JSON puro de volta (ex.:
      # ProcessEtJob) mesmo em conversas que nunca usaram tool nenhuma.
      with_tool(SearchLegalNormsTool.new) if Cal::Client.configured? && messages.exists?(role: "tool")

      instruction = create_user_message(prompt, with: with)
      instruction.update!(internal: true)
      complete
      messages.where(role: "assistant").order(:created_at).last&.update!(internal: true) if hide_response
    end
  end

  # RespondToMessageJob usa isto no lugar de #complete cru — mesmo pg_advisory_xact_lock que
  # #ask_internally já usa por baixo (ver with_ai_lock), então os dois lados se esperam.
  #
  # Achado ao vivo (conversa 35/proposta 21, 2026-09): GenerateProposalDocumentTool roda DENTRO
  # desta chamada — ela grava a mensagem de tool_use, executa a ferramenta (que enfileira
  # SuggestScheduleJob) e só DEPOIS grava o tool_result correspondente. SuggestScheduleJob
  # (background de propósito, ver CLAUDE.md seção 8) pode ser pego por outro worker do Solid
  # Queue nesse intervalo — antes de #complete (chamado sem lock) ter tido a chance de gravar o
  # tool_result. A chamada de dentro de SuggestScheduleJob (via #ask_internally, que JÁ usa
  # with_ai_lock) lia a conversa nesse estado incompleto — último bloco de histórico era um
  # tool_use sem tool_result — e o Bedrock rejeitava com "tool_use ids were found without
  # tool_result blocks immediately after". RubyLLM destruía a mensagem que estava criando pra
  # essa chamada, e o cronograma nunca era sugerido (0 itens pra sempre, igual o bug original de
  # reentrância, mas por uma causa diferente — ali era o MESMO processo reentrando #complete; aqui
  # são DOIS processos disputando a mesma conversa). Como nada dentro de #complete chama
  # #ask_internally de forma síncrona (foi exatamente isso que a correção da reentrância
  # eliminou), colocar o turno inteiro dentro do mesmo advisory lock é seguro — não reentra a
  # trava no mesmo processo, só faz SuggestScheduleJob (sessão/processo diferente) esperar o
  # commit da transação deste turno antes de ler o histórico.
  def complete_with_lock(&block)
    with_ai_lock { complete(&block) }
  end

  # Usa o operador jsonb `||` do Postgres pra fazer o merge no banco (atômico),
  # em vez de merge em Ruby sobre o hash em memória — necessário porque os jobs
  # (tr/comp_docs) rodam em paralelo de verdade via Solid Queue, e um merge em
  # Ruby baseado em snapshot desatualizado perde a escrita de outro job (last-write-wins).
  def mark_step!(step, status)
    merge_processing_steps!(step.to_s => status)
    reload
    broadcast_refresh
  end

  # Chamado ao final de cada job de processamento; dispara o GenerateSummaryJob
  # assim que tr/comp_docs estiverem todos resolvidos (done/skipped/failed).
  # O update_all condicional evita disparar o resumo duas vezes se dois jobs terminarem ao mesmo tempo.
  def check_processing_complete!
    return unless PROCESSING_STEPS.all? { |step| %w[done skipped failed].include?(processing_step_status(step)) }

    guarded_update = self.class.where(id: id)
                         .where("processing_steps ->> 'summary' = ?", "pending")
                         .update_all([ "processing_steps = processing_steps || ?::jsonb", { "summary" => "queued" }.to_json ])
    return unless guarded_update.positive?

    GenerateSummaryJob.perform_later(id)
  end

  private
    # LlmMessageOrdering: quais ToolCall cada mensagem disparou, e de qual ToolCall veio cada
    # resultado. Uma consulta só pro histórico inteiro.
    def tool_call_ids_by_message(message_ids)
      ToolCall.where(message_id: message_ids).order(:id).pluck(:message_id, :id)
        .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    end

    def tool_result_call_id(message) = message.tool_call_id

    # O valor que a IA respondeu continua registrado como achado normal (source_kind "et"/"tr") —
    # este aqui é o aviso do SISTEMA de que ele não casa com nada cadastrado. Fica visível no
    # resumo, no snapshot que a IA lê a cada turno e na tela de achados. NUNCA bloqueia nada
    # (2026-09) — uma proposta pode ter outros tipos já associados, ou nenhum (acompanhamento); um
    # achado fora do catálogo é só informação pro consultor decidir se cadastra o que falta.
    # 1 achado por VALOR (não por lote) — assign_study_types_from_findings! roda de novo a cada
    # achado novo de "tipo_estudo" (ET e TR podem repetir o mesmo valor não-cadastrado), e o check
    # de valor EXATO (não `LIKE` de prefixo) evita duplicar por valor já sinalizado antes.
    def flag_study_type_out_of_catalog(values)
      Array(values).uniq.each do |value|
        next if value.blank?
        next if project_findings.where(field: "outro", source_kind: "sistema",
          value: "#{STUDY_TYPE_OUT_OF_CATALOG}: #{value}").exists?

        project_findings.create!(
          field: "outro", nature: "sugestao", source_kind: "sistema",
          value: "#{STUDY_TYPE_OUT_OF_CATALOG}: #{value}",
          excerpt: "A IA identificou este tipo de estudo nos documentos, mas ele não existe em " \
                   "Configurações > Tipos de Estudo. Se nenhum tipo já associado a esta proposta " \
                   "for equivalente, o consultor pode marcar um tipo cadastrado ou cadastrar este " \
                   "em Configurações > Tipos de Estudo."
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("[Conversation] não consegui registrar tipo de estudo fora do cadastro: #{e.message}")
      end
    end

    # pg_advisory_xact_lock bloqueia outras chamadas com a MESMA chave (id da conversa) até a
    # transação atual terminar — libera sozinho no commit/rollback, sem risco de esquecer um
    # unlock manual (e sem o problema de pg_advisory_lock/unlock exigirem a mesma conexão, que o
    # pool de conexões do Rails não garante entre chamadas separadas).
    def with_ai_lock
      self.class.transaction do
        self.class.connection.execute("SELECT pg_advisory_xact_lock(#{id.to_i})")
        yield
      end
    end

    def merge_processing_steps!(patch)
      self.class.where(id: id).update_all([ "processing_steps = processing_steps || ?::jsonb", patch.to_json ])
    end

    # O que foi extraído dos documentos desta proposta, com o código de citação de cada item.
    # Sem o trecho de propósito: repeti-lo a cada turno custaria contexto para algo que só o
    # consultor precisa ver, e ele vê ao clicar no código.
    def findings_snapshot_text
      findings = project_findings.active.includes(:source_blob).order(:field, :id)
      return "" if findings.empty?

      <<~TEXT
        [ACHADOS DESTA PROPOSTA] (extraídos dos documentos por você mesmo, com a origem registrada;
        cite o código entre colchetes ao afirmar qualquer um deles):
        #{findings.map(&:to_context_line).join("\n")}
      TEXT
    end

    def framing_gate_snapshot_text
      return "" unless framing_confirmation_required?

      <<~TEXT
        [BLOQUEIO: ENQUADRAMENTO NÃO CONFIRMADO] Nenhum consultor confirmou ainda a licença e o(s)
        estudo(s) desta proposta. Enquanto isso, NÃO chame generate_proposal_document e não diga que
        vai gerar: peça ao consultor que confira o enquadramento e clique em "Confirmar enquadramento"
        no painel à esquerda do chat (se houver divergência legislação × pedido, ele decide no card
        antes). Tirar dúvida, ajustar escopo e conversar continuam liberados.
      TEXT
    end

    # Legislação × pedido do cliente (pedido da Sara, 2026-09-29): a proposta SEMPRE diz o que a
    # legislação enquadra e o que foi solicitado — mesmo depois de o consultor escolher um lado
    # ("de acordo com a legislação o estudo é X; entretanto, foi solicitado Y"). O que muda com a
    # decisão é só a frase final: o que esta proposta contempla, ou que a CONTRATANTE define.
    def legal_framing_snapshot_text
      conflicts = project_conflicts.where.not(status: "dismissed").includes(findings: :source_blob).select(&:legal_framing?)
      return "" if conflicts.empty?

      lines = conflicts.map do |conflict|
        legal, requested = conflict.findings.partition { |finding| finding.source_kind == "cal" }
        decision = case conflict.status
        when "resolved" then "o consultor decidiu: a proposta contempla #{conflict.findings.first&.superseded_by&.value}"
        when "client" then "o consultor decidiu LEVAR AO CLIENTE: a proposta segue a legislação e a CONTRATANTE confirma"
        else "o consultor AINDA NÃO decidiu"
        end
        "- #{conflict.field_label}: legislação diz #{legal.map { |f| "#{f.value} (#{f.locator.presence || f.source_label})" }.join(' / ')}; " \
          "foi solicitado #{requested.map { |f| "#{f.value} (#{f.source_label})" }.join(' / ')} — #{decision}"
      end

      <<~TEXT
        [ENQUADRAMENTO LEGAL × O QUE FOI SOLICITADO]
        #{lines.join("\n")}

        Ao gerar a proposta, o PRIMEIRO parágrafo de escopo_e_metodologia registra isso, sempre:
        "De acordo com a legislação aplicável (<tipo e número da norma, sem nome nem sigla do
        órgão>), o empreendimento se enquadra em <X>; entretanto, <o Termo de Referência / a
        solicitação da CONTRATANTE> prevê <Y>." E termina conforme a decisão:
        - decidido: "A presente proposta contempla <o escolhido>."
        - levar ao cliente: "Esta proposta contempla o enquadramento legal (<o da legislação>).
          Cabe à CONTRATANTE confirmar; optando-se por <o solicitado>, escopo e preço serão revistos."
        - ainda não decidido: igual a "levar ao cliente", e avise o consultor no chat que a
          decisão está pendente no card da divergência — enquanto isso a geração fica travada.
        Nunca escolha um lado por conta própria.
      TEXT
    end

    # Divergência aberta TRAVA a geração (2026-09-30) — e a IA precisa saber que existe, senão escolhe um
    # dos valores por conta própria e o consultor nunca fica sabendo que havia dois.
    def conflicts_snapshot_text
      conflicts = project_conflicts.where(status: %w[open waived]).includes(findings: :source_blob).reject(&:legal_framing?)
      return "" if conflicts.empty?

      open, waived = conflicts.partition(&:open?)
      [
        (<<~TEXT if open.any?),
          [DIVERGÊNCIAS ABERTAS ENTRE OS DOCUMENTOS] (o consultor ainda não decidiu — TRAVAM a geração):
          #{open.map(&:to_context_line).join("\n")}
          NUNCA escolha um dos valores sozinho. Enquanto houver divergência aberta, generate_proposal_document
          recusa gerar: apresente os pontos e peça ao consultor que decida no card (ou libere com
          "Seguir sem decidir", explicando o motivo).
        TEXT
        (<<~TEXT if waived.any?)
          [DIVERGÊNCIAS LIBERADAS SEM DECISÃO] (o consultor mandou seguir assim):
          #{waived.map { |c| "#{c.to_context_line} — motivo: #{c.resolution_note}" }.join("\n")}
          No texto da proposta, trate cada uma como ressalva, cobrindo os dois cenários ou marcando "A
          confirmar com o cliente".
        TEXT
      ].compact.join("\n")
    end

    # Pendências (ProjectIssue): as abertas travam a geração; as respondidas são DADO que a proposta
    # tem que usar; as liberadas sem resposta viram ressalva/"a confirmar".
    def issues_snapshot_text
      issues = project_issues.order(:id).to_a
      return "" if issues.empty?

      open, closed = issues.partition(&:open?)
      [
        (<<~TEXT if open.any?),
          [PENDÊNCIAS ABERTAS — TRAVAM A GERAÇÃO] (questionamentos sem resposta do consultor):
          #{open.map(&:to_context_line).join("\n")}
          Enquanto houver pendência aberta, generate_proposal_document recusa gerar. Se o consultor
          pedir pra gerar, NÃO prometa gerar: liste as pendências e diga que ele responde no card de
          cada uma (ou aqui no chat) ou libera com "Seguir sem resposta" explicando o motivo. Se ele
          RESPONDER uma delas no chat, registre com answer_pending_issue.
        TEXT
        (<<~TEXT if closed.any?)
          [PENDÊNCIAS JÁ TRATADAS]
          #{closed.map(&:to_context_line).join("\n")}
          Use as respostas no texto da proposta; o que foi liberado sem resposta sai como ressalva ou
          "A confirmar com o cliente".
        TEXT
      ].compact.join("\n")
    end

    def no_proposal_state_text
      <<~TEXT
        #{PROPOSAL_STATE_MARKER} (gerado pelo sistema, sempre reflete o estado real — não pergunte
        isso ao consultor, apenas use como fato já resolvido):
        - Local da logística: #{logistics_location_text(Logistics::DestinationResolver.for_conversation(self))}
        - A proposta AINDA NÃO FOI CRIADA no sistema, mas isso NÃO bloqueia pedir a técnica — a
          ferramenta generate_proposal_document cria a proposta sozinha (com a equipe já sugerida
          pela IA) na hora que você a chama de verdade, sem precisar que o consultor clique em nada
          na tela antes. Se ele pedir a proposta técnica, siga o passo a passo normal (itens 1, 3,
          4, 9) e chame a ferramenta — ela cuida do resto. Tipo de estudo NÃO é pré-requisito —
          uma proposta pode ter vários, ou nenhum (proposta de acompanhamento); não existe
          pendência aqui: chame a ferramenta (não invente "clique em Avançar para Precificação").
      TEXT
    end

    # De onde vem o destino da logística (Logistics::DestinationResolver) — sem ele não há distância,
    # combustível nem busca de hospedagem, e a IA precisa saber que pode resolver isso pelo chat.
    def logistics_location_text(destination)
      return "#{destination.label} (fonte: #{destination.source})" if destination

      "NÃO DEFINIDO — sem KMZ e sem município inequívoco (com UF) nos documentos. Se o ET/TR, um " \
        "complementar ou o consultor indicar onde fica o projeto, chame set_project_location com " \
        "\"Município/UF\"; se não souber o município ou a UF com segurança, pergunte ao consultor."
    end

    def campaign_lodging_text(campaign)
      label = case campaign.lodging_mode
      when "hotel" then "#{campaign.lodging_name}#{" (#{campaign.lodging_city})" if campaign.lodging_city.present?}, R$ #{campaign.lodging_price_per_night}/noite"
      when "alojamento" then "#{campaign.lodging_name}, R$ #{campaign.lodging_price_per_night}/noite"
      when "cliente" then "fornecida pelo cliente"
      else "a definir na Tela de Precificação (usando o valor padrão)"
      end
      label += ", #{campaign.commute_hours}h por trecho até a área" if campaign.commute_hours.positive?
      label
    end

    # Proposta aprovada e reaberta pra ajuste (Proposal#reopen!) — a IA precisa saber que ela voltou a
    # ser editável por pedido do cliente, e qual foi o preço aprovado antes.
    def proposal_reopen_note
      return "" unless proposal.reopened_at && proposal.status != "approved"

      note = " (REABERTA para ajuste em #{proposal.reopened_at.strftime('%d/%m/%Y')} depois de aprovada"
      note += " por R$ #{proposal.approved_total}" if proposal.approved_total
      note += "; motivo: #{proposal.reopen_reason}" if proposal.reopen_reason.present?
      note + " — precisa ser aprovada de novo na Tela de Precificação)"
    end

    def proposal_state_text
      pricing = proposal.project_pricing
      items = pricing.pricing_items.includes(:pricing_enterprise, field_campaigns: :ibge_municipality, proposal_professionals: :professional).to_a
      lines = items.map do |item|
        factor = item.days_factor
        team = item.proposal_professionals.map do |pp|
          extra = pp.commute_extra_days(factor)
          "    - #{pp.professional.name}: #{pp.deliverable_name} (#{pp.man_hours} HH, #{pp.field_days} diária(s)#{" + #{extra} por deslocamento até a hospedagem" if extra.positive?})"
        end
        campaigns = item.field_campaigns.map { |c| "    - campo \"#{c.description}\": #{c.people} pessoa(s), #{c.days} dia(s) em campo#{" (#{c.effective_days} com o deslocamento diário)" if c.extra_days.positive?}, #{c.vehicles} #{c.vehicle_type}#{", local #{c.ibge_municipality.label}" if c.ibge_municipality}, hospedagem: #{campaign_lodging_text(c)}" }
        [ "  Item \"#{item.name}\"#{" (empreendimento #{item.pricing_enterprise.name})" if item.pricing_enterprise}:", *team, *campaigns ].join("\n")
      end.join("\n")

      external_costs = pricing.external_costs.map { |c| "#{c['description']} (R$ #{c['value']})" }.join(", ")
      team_all_zero = pricing.proposal_professionals.none? || pricing.proposal_professionals.all? { |pp| pp.man_hours.zero? && pp.field_days.zero? }
      logistics_filled = pricing.logistics_total.positive? || pricing.distance_km.positive?

      <<~TEXT
        #{PROPOSAL_STATE_MARKER} (gerado pelo sistema, sempre reflete o estado real da Tela de
        Precificação — não pergunte isso ao consultor, apenas use como fato já resolvido):
        - Status da proposta: #{proposal.status}#{proposal_reopen_note}
        - Nome do arquivo: #{proposal.docx_filename_override.presence&.then { |n| "definido pelo consultor (\"#{n}\") — a ferramenta já usa esse nome sozinha, não precisa reenviar" } || "padrão do sistema (número + cliente + escopo + revisão)"}
        - Formato do documento: #{proposal.document_split == "separated" ? "técnica e comercial separadas" : "documento único"}
        - Itens da precificação (equipe e campos de cada um):
        #{lines.presence || "  (nenhuma linha definida ainda)"}
        - Empreendimentos: #{pricing.pricing_enterprises.map(&:name).join(", ").presence || "um só"}
        - Quadro de preço no documento: #{ProjectPricing::PRICE_PRESENTATIONS.fetch(proposal.price_presentation_mode)}
        - Local da logística: #{logistics_location_text(Logistics::DestinationResolver.resolve(proposal))}
        - Logística: #{pricing.distance_km} km até o projeto, R$ #{pricing.logistics_total} nos campos#{logistics_filled ? " (parâmetros preenchidos)" : " (parâmetros ainda não preenchidos)"}
        - Custos externos: #{external_costs.presence || "nenhum lançado"}
        - Preço total calculado: R$ #{pricing.total_value}
        #{team_all_zero || !logistics_filled ? proposal_state_zero_warning : ""}
      TEXT
    end

    # Nota anexada ao [ESTADO ATUAL DA PROPOSTA] só quando equipe/logística ainda estão zeradas —
    # achado ao vivo em produção (2026-09): mesmo com a checklist interna já dizendo "nunca
    # bloqueia por causa do cronograma", a IA reagia aos números 0h/0km deste MESMO bloco
    # inventando uma recusa ("problema estrutural", "documento vazio de conteúdo executivo") e
    # pedindo pro consultor preencher horas/dias de campo manualmente pelo chat antes de tentar de
    # novo — nunca chamando generate_proposal_document. Repetir a regra aqui, ao lado do número
    # que dispara a reação, é mais eficaz do que só a checklist (mais distante no histórico).
    def proposal_state_zero_warning
      "AVISO: equipe com 0h e/ou logística zerada acima são o estado NORMAL antes da 1ª geração — " \
      "NÃO é um problema, e NÃO é motivo pra recusar chamar generate_proposal_document nem pra " \
      "pedir esses números pelo chat antes de tentar. A ferramenta sugere/calcula equipe " \
      "(template determinístico), cronograma (sugestão automática em background) e logística " \
      "(distância/combustível via geolocalização) sozinha, a cada chamada. Chame a ferramenta " \
      "normalmente agora; se algo específico não puder ser calculado, ela mesma avisa isso na " \
      "própria resposta — nunca escreva você mesmo um aviso de bloqueio por causa destes números."
    end
end
