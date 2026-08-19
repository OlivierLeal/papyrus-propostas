class Conversation < ApplicationRecord
  acts_as_chat

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

    Qualquer pedido fora desse escopo (perguntas sem relação com este projeto ou com licenciamento
    ambiental, código, receitas, tarefas genéricas ou qualquer assunto alheio a este atendimento):
    recuse em UMA frase curta, sem elaborar, redirecionando o consultor de volta para a proposta.

    Você nunca calcula preços, horas ou valores em R$ — isso é feito por um motor determinístico à
    parte. Sua função é só identificar e organizar informações de escopo. Responda sempre em português.
  TEXT

  # Passo a passo interno da Papyrus pra elaborar uma Proposta Técnica (documento cedido pela
  # empresa). Uso interno da IA — não repita a lista inteira pro consultor a menos que ele peça.
  PROPOSAL_CHECKLIST_INSTRUCTIONS = <<~TEXT.freeze
    Passo a passo interno da Papyrus pra elaboração de uma Proposta Técnica:

    1. Ler o TR e entender o que está sendo pedido. Nem sempre o cliente envia o TR, e cada empresa
       apresenta as informações de um jeito diferente.
    2. Se faltar documento necessário ou houver dúvida sobre o escopo, isso precisa ser resolvido
       com o cliente (e-mail via Charlene) antes de prosseguir.
    3. Enquadrar o empreendimento no órgão ambiental do estado onde fica o projeto (empreendimentos
       em 2+ estados são federais, IBAMA).
    4. Pesquisar propostas anteriores semelhantes em escopo, como base pra estruturar esta.
    5. Confirmar dias de campo e deslocamento com a equipe técnica, se houver trabalho de campo.
    6. Verificar se precisa de orçamento externo de prestadores (fauna, flora, meio físico,
       arqueologia) — a flora normalmente é equipe interna.
    7. Se for solicitar orçamento externo, confirmar se o prestador já tem NDA assinado.
    8. Ter a planilha de orçamento completa: dias de campo, deslocamento, valores dos prestadores,
       logística discriminada.
    9. Consultar escopos e equipes técnicas já usados em serviços parecidos.
    10. Se o TR exigir cronograma de execução, incluir — ainda não temos suporte estruturado pra
        isso no sistema, avise o consultor que precisa ser montado à parte por enquanto.
    11. Registro da proposta no controle interno (rede) e (13) revisão com a Sara acontecem depois
        de gerado o rascunho — são lembretes pro consultor, nunca bloqueiam a geração.

    Quando o consultor pedir para gerar a proposta técnica e/ou comercial, verifique os itens 1, 3,
    4, 5, 6, 8 e 9 contra o que você já sabe desta conversa (TR, documentos complementares, equipe e
    preço já definidos). Se faltar informação que bloqueia mesmo (TR pouco claro, dias de campo não
    definidos, orçamento externo pendente, planilha de preço incompleta), NÃO chame a ferramenta —
    diga exatamente o que falta e peça ao consultor. Os itens 2, 7 e 11 são administrativos e
    internos da Papyrus — apenas lembre o consultor deles, nunca impeça a geração por causa deles.

    Se nada bloquear, chame a ferramenta generate_proposal_document com o texto de cada seção
    baseado em tudo que já foi lido nesta conversa (TR, documentos complementares, propostas
    anteriores semelhantes). Nunca invente nome de cliente, CNPJ ou contato que você não tenha
    visto em algum documento — escreva "A confirmar" nesses campos em vez de adivinhar. Preço,
    equipe e formato do documento (único ou separado) a ferramenta já busca sozinha do sistema.
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

  def apply_system_instructions!
    with_instructions(SYSTEM_INSTRUCTIONS)
    with_instructions(PROPOSAL_CHECKLIST_INSTRUCTIONS, append: true)
    messages.where(role: "system").find_each { |message| message.update!(internal: true) }
  end

  PROPOSAL_STATE_MARKER = "[ESTADO ATUAL DA PROPOSTA]".freeze

  # A IA só enxerga o que está no histórico do chat — os números da Tela de Precificação (que o
  # consultor edita direto, fora do chat) nunca chegam até ela por conta própria. Sem isso, ao
  # pedir "gera a proposta" ela acha que nada foi definido e trava à toa. Chamado antes de cada
  # complete (ver RespondToMessageJob); apaga a versão anterior e recria, então nunca acumula
  # nem fica desatualizado — e só existe depois que a proposta é criada (sem custo antes disso).
  def refresh_proposal_state_snapshot!
    return unless proposal

    messages.where(role: "user", internal: true).where("content LIKE ?", "#{PROPOSAL_STATE_MARKER}%").destroy_all
    snapshot = create_user_message(proposal_state_text)
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
  def ask_internally(prompt, with: nil, hide_response: false)
    instruction = create_user_message(prompt, with: with)
    instruction.update!(internal: true)
    complete
    messages.where(role: "assistant").order(:created_at).last&.update!(internal: true) if hide_response
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
    def merge_processing_steps!(patch)
      self.class.where(id: id).update_all([ "processing_steps = processing_steps || ?::jsonb", patch.to_json ])
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
