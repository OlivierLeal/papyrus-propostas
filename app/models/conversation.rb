class Conversation < ApplicationRecord
  acts_as_chat

  has_many :knowledge_notes, dependent: :destroy
  # O entendimento estruturado do projeto (o que foi lido, onde, e com que grau de certeza) e as
  # divergências entre documentos — ver ProjectFinding e ProjectConflict.
  has_many :project_findings, dependent: :destroy
  has_many :project_conflicts, dependent: :destroy

  STATUSES = %w[setup processing reviewing pricing completed].freeze

  STATUS_LABELS = {
    "setup" => "Configuração",
    "processing" => "Processando",
    "reviewing" => "Em revisão",
    "pricing" => "Precificação",
    "completed" => "Concluída"
  }.freeze

  # Etapas de processamento em background disparadas ao confirmar o setup.
  # "summary" roda depois que as etapas abaixo terminam (done/skipped/failed).
  PROCESSING_STEPS = %w[tr comp_docs kmz].freeze

  PROCESSING_STEP_LABELS = {
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
    - Analisar o Termo de Referência (TR), o KMZ e os documentos complementares desta proposta.
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

    Fatos fixos sobre os documentos desta conversa:
    - O KMZ enviado pelo consultor JÁ É a poligonal oficial da área do empreendimento (coordenadas
      reais do imóvel, não um esboço/visualização). Nunca trate isso como informação pendente nem
      peça ao consultor uma "poligonal oficial georreferenciada" separada. Se o TR exigir que o
      MAPA FINAL a ser entregue pela Papyrus seja georreferenciado (ex.: SIRGAS 2000), isso é um
      requisito de formato do produto que a Papyrus vai produzir a partir do KMZ — não um dado que
      falta o cliente fornecer antes de começar.

    Você nunca calcula preços, horas ou valores em R$ — isso é feito por um motor determinístico à
    parte. Sua função é só identificar e organizar informações de escopo. Responda sempre em português.
  TEXT

  # Passo a passo interno da Papyrus pra elaborar uma Proposta Técnica (documento cedido pela
  # empresa, atualizado por eles em 2026-08 — mesma numeração do arquivo original). Uso interno
  # da IA — não repita a lista inteira pro consultor a menos que ele peça.
  PROPOSAL_CHECKLIST_INSTRUCTIONS = <<~TEXT.freeze
    Passo a passo interno da Papyrus pra elaboração de uma Proposta Técnica:

    1. Criar a pasta na rede seguindo o padrão de nome da proposta (número + cliente + escopo +
       revisão) — administrativo, feito fora do sistema.
    2. Adicionar a proposta no controle de Propostas da rede (Y:\\6) Controles) — administrativo.
    3. Ler o TR e entender o que está sendo pedido. Nem sempre o cliente envia o TR, e cada empresa
       apresenta as informações de um jeito diferente. Dúvida sobre o CONTEÚDO do TR (o que está
       sendo pedido tecnicamente) é uma questão interna — o consultor resolve com Molina ou Pedro,
       não precisa de e-mail ao cliente.
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
    12. Se a proposta exigir cronograma, histograma ou organograma de execução, incluir — ainda não
        temos suporte estruturado pra isso no sistema, avise o consultor que precisa ser montado à
        parte por enquanto.
    13. Enviar para Sara ou Charlene revisar — acontece depois de gerado o rascunho, é lembrete pro
        consultor, nunca bloqueia a geração.

    A proposta técnica e a comercial têm bloqueios DIFERENTES — a ferramenta generate_proposal_
    document já sabe disso sozinha (olha o status da proposta, sempre visível no [ESTADO ATUAL DA
    PROPOSTA] mais abaixo no histórico), mas você precisa saber pra decidir SE chama a ferramenta
    e o que dizer ao consultor:

    - Se o pedido for só a proposta TÉCNICA (ou o consultor não especificar e a proposta ainda
      estiver com status "draft"): verifique só os itens 3, 5, 6 e 11 — e mesmo esses, só bloqueiam
      de verdade se forem IMPOSSÍVEIS de resolver com o que você já tem (ex.: item 3 bloqueia só se
      não houver TR nenhum anexado; item 5 bloqueia só se você não souber nem dizer se o órgão é
      estadual ou federal). Os itens 7, 8 e 10 (dias de campo, orçamento externo, planilha de preço)
      são coisa de PRECIFICAÇÃO — não bloqueiam a técnica, nem pergunte isso pro consultor nesse
      caso. DETALHE regulatório incerto (data exata de perímetro urbano, percentual de vegetação a
      manter, necessidade de inventário florestal, documentação geológica pendente, etc.) TAMBÉM
      NÃO bloqueia — escreva a condicionante no texto da seção cabível cobrindo os cenários
      possíveis, ou como "A confirmar com o cliente" (mesma regra que já vale pra nome/CNPJ
      incerto), e gere a proposta assim mesmo. O consultor prefere um rascunho pra revisar e
      ajustar no chat depois a ficar esperando um menu de opções antes de ver qualquer coisa —
      não pergunte "Opção A/B/C", só gere. Se 3, 5, 6 e 11 estiverem minimamente resolvidos, chame a
      ferramenta — com a proposta em "draft" ela gera só a proposta_tecnica.docx sozinha.
    - Se o pedido for a proposta COMERCIAL ou o documento completo (ou "a proposta" sem
      qualificar, quando o status já não é mais "draft"): verifique também os itens 7, 8 e 10. Além
      disso, a ferramenta só gera esse lado se o status já for "priced" ou "approved" — se o
      [ESTADO ATUAL DA PROPOSTA] mostrar "draft" ou "pricing", NÃO chame a ferramenta: diga ao
      consultor que a Tela de Precificação precisa ser revisada e confirmada antes (não peça os
      valores um por um pelo chat — quem ajusta isso é o consultor naquela tela).

    Os itens 1, 2, 4, 9 e 13 são administrativos e internos da Papyrus (pasta na rede, controle de
    propostas, e-mail ao cliente, NDA de prestador, revisão com Sara/Charlene) — apenas lembre o
    consultor deles quando fizer sentido, nunca impeça a geração por causa deles.

    Chame a ferramenta generate_proposal_document com o texto de cada seção baseado em tudo que já
    foi lido nesta conversa (TR, documentos complementares, propostas anteriores semelhantes).
    Nunca invente nome de cliente, CNPJ ou contato que você não tenha visto em algum documento —
    escreva "A confirmar" nesses campos em vez de adivinhar. Preço, equipe e formato do documento
    (único ou separado) a ferramenta já busca sozinha do sistema.
  TEXT

  belongs_to :user
  # Não é escolhido no setup — a IA identifica lendo a TR (ver ProcessTrJob#assign_study_type!),
  # restrito ao menu real de StudyType. Fica nil até isso acontecer (ou se não houver TR).
  belongs_to :study_type, optional: true
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

  # Cria a proposta (e a equipe sugerida pela IA) sob demanda — chamado tanto pelo botão "Avançar
  # para Precificação" quanto pelo chat, na primeira vez que o consultor pede pra gerar algo.
  # Antes disso só existia via clique no botão, e a IA acabava respondendo "clique em Avançar pra
  # Precificação" pra QUALQUER pedido de geração, mesmo só-técnica — visto na prática confundindo
  # o consultor ("não quero avançar pra preço ainda, quero só a técnica"). Continua sendo a mesma
  # Proposal/ProjectPricing de sempre por baixo (a técnica em draft já usa isso — ver
  # GenerateProposalDocumentTool); só o gatilho de criação deixou de exigir a tela.
  # Retorna nil (sem criar nada) se faltar pré-requisito real (revisão concluída, tipo de estudo
  # identificado) — quem chama decide o que fazer com isso.
  def ensure_proposal!
    return proposal if proposal.present?
    return nil unless status == "reviewing" && study_type.present?

    new_proposal = create_proposal!(status: "draft")
    new_proposal.build_with_ai_suggested_team!
    update!(status: "pricing")
    new_proposal
  end

  def apply_system_instructions!
    with_instructions(SYSTEM_INSTRUCTIONS)
    with_instructions(PROPOSAL_CHECKLIST_INSTRUCTIONS, append: true)
    messages.where(role: "system").find_each { |message| message.update!(internal: true) }
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
             findings_snapshot_text, conflicts_snapshot_text ].compact_blank.join("\n")
    snapshot = create_user_message(text)
    snapshot.update!(internal: true)
  end

  # Só mensagens internal: false — o ruby_llm, ao enviar um anexo pra IA via `with:` em
  # ask_internally, persiste uma cópia do attachment na própria mensagem de instrução (internal:
  # true) que carrega o prompt. Sem esse filtro, cada chamada a ask_internally(with: anexo) faz
  # esse anexo "duplicar" nesta lista — TR com 2 arquivos virava 4 depois do primeiro
  # processamento, por exemplo.
  def attachments_of_kind(kind)
    messages.where(internal: false).flat_map(&:attachments).select { |attachment| attachment.blob.metadata["kind"] == kind.to_s }
  end

  def attachment_of_kind(kind)
    attachments_of_kind(kind).first
  end

  def processing_step_status(step)
    processing_steps[step.to_s] || "pending"
  end

  def processing_step_label(step)
    PROCESSING_STEP_LABELS.fetch(step.to_s, step.to_s)
  end

  # Manda uma pergunta pra IA sem expor a instrução (prompt de sistema do job/controller) na
  # conversa que o consultor vê — só a resposta da IA aparece na tela de revisão/chat.
  # hide_response: true também esconde a resposta da IA do chat (ex.: extrações em JSON que não
  # são pra consultor ler) — por padrão só a instrução fica escondida, porque GenerateSummaryJob
  # depende de ask_internally pra gerar o resumo que o consultor DEVE ver na tela de revisão.
  #
  # with_ai_lock: os 3 jobs de processamento do setup (TR/KMZ/complementares) rodam de propósito
  # em paralelo (config/queue.yml tem 3 threads de worker) — mas ProcessTrJob e ProcessCompDocsJob
  # chamam ask_internally na MESMA conversa ao mesmo tempo. Sem essa trava, duas chamadas
  # concorrentes disputam "a última mensagem do assistente" (linha abaixo, e também em
  # ProcessTrJob#assign_study_type!), e uma rouba a resposta da outra — visto na prática numa
  # conversa real: a extração estruturada do TR sumiu (perdida pra uma resposta duplicada dos
  # complementares) e o tipo de estudo nunca foi identificado. pg_advisory_xact_lock serializa só
  # as chamadas da MESMA conversa (id como chave) — outras conversas continuam livres pra rodar em
  # paralelo — e libera sozinho quando a transação termina, sem precisar de unlock manual.
  def ask_internally(prompt, with: nil, hide_response: false)
    with_ai_lock do
      instruction = create_user_message(prompt, with: with)
      instruction.update!(internal: true)
      complete
      messages.where(role: "assistant").order(:created_at).last&.update!(internal: true) if hide_response
    end
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

    # Divergência aberta não bloqueia nada — mas a IA precisa saber que existe, senão escolhe um
    # dos valores por conta própria e o consultor nunca fica sabendo que havia dois.
    def conflicts_snapshot_text
      conflicts = project_conflicts.open.includes(findings: :source_blob)
      return "" if conflicts.empty?

      <<~TEXT
        [DIVERGÊNCIAS ABERTAS ENTRE OS DOCUMENTOS] (o consultor ainda não decidiu qual valor vale):
        #{conflicts.map(&:to_context_line).join("\n")}

        NUNCA escolha um dos valores sozinho e nunca apresente um deles como se fosse o único.
        Ao escrever qualquer seção que dependa de um desses pontos, trate a divergência como
        ressalva no texto — cobrindo os dois cenários ou marcando "A confirmar com o cliente",
        mesma regra que já vale para dado incerto. Isso NÃO impede gerar a proposta.
      TEXT
    end

    def no_proposal_state_text
      <<~TEXT
        #{PROPOSAL_STATE_MARKER} (gerado pelo sistema, sempre reflete o estado real — não pergunte
        isso ao consultor, apenas use como fato já resolvido):
        - A proposta AINDA NÃO FOI CRIADA no sistema, mas isso NÃO bloqueia pedir a técnica — a
          ferramenta generate_proposal_document cria a proposta sozinha (com a equipe já sugerida
          pela IA) na hora que você a chama de verdade, sem precisar que o consultor clique em nada
          na tela antes. Se ele pedir a proposta técnica, siga o passo a passo normal (itens 1, 3,
          4, 9) e chame a ferramenta — ela cuida do resto. O único caso em que isso NÃO funciona é
          se o tipo de estudo ainda não foi identificado (TR ainda em processamento) ou a revisão
          ainda não foi concluída — nesse caso a ferramenta devolve um erro explicando; só então
          diga ao consultor o que falta (não invente "clique em Avançar para Precificação" fora
          desse caso específico).
      TEXT
    end

    def proposal_state_text
      pricing = proposal.project_pricing
      lines = pricing.proposal_professionals.includes(:professional).map do |pp|
        "- #{pp.professional.name}: #{pp.deliverable_name} (#{pp.hours_office}h escritório, #{pp.hours_field}h campo)"
      end.join("\n")

      external_costs = pricing.external_costs.map { |c| "#{c['description']} (R$ #{c['value']})" }.join(", ")
      logistics_filled = pricing.logistics_total.positive? || pricing.distance_km.positive?

      <<~TEXT
        #{PROPOSAL_STATE_MARKER} (gerado pelo sistema, sempre reflete o estado real da Tela de
        Precificação — não pergunte isso ao consultor, apenas use como fato já resolvido):
        - Status da proposta: #{proposal.status}
        - Formato do documento: #{proposal.document_split == "separated" ? "técnica e comercial separadas" : "documento único"}
        - Equipe e horas definidas:
        #{lines.presence || "  (nenhuma linha definida ainda)"}
        - Logística: #{pricing.logistics_days} dias de campo, #{pricing.distance_km} km de distância#{logistics_filled ? " (parâmetros preenchidos)" : " (parâmetros ainda não preenchidos)"}
        - Custos externos: #{external_costs.presence || "nenhum lançado"}
        - Preço total calculado: R$ #{pricing.total_value}
      TEXT
    end
end
