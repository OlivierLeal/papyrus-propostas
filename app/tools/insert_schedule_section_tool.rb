# Insere SÓ a seção de cronograma (tabela Quadro 9 + infográfico de linha do tempo, página
# paisagem) num .docx JÁ FINALIZADO desta proposta que o consultor anexou no chat — o caso de
# "gerei a proposta pelo sistema, revisei no Word por fora, e agora quero só o cronograma de
# volta". Não refaz o documento, não gera texto: o cronograma vem do que já está cadastrado na
# proposta (Tela de Precificação / sugestão da IA na criação). Ver CLAUDE.md seção 8 e
# ProposalDocxFiller#insert_schedule_section.
class InsertScheduleSectionTool < RubyLLM::Tool
  description <<~DESC
    Insere (ou atualiza) apenas a seção de cronograma — a tabela do Quadro 9 e o infográfico de
    linha do tempo, em página paisagem — num arquivo .docx JÁ FINALIZADO desta proposta que o
    consultor anexou no chat. Use quando o consultor subir a versão revisada/final do documento e
    pedir só o cronograma/infográfico de volta, sem refazer a proposta inteira.

    Não gera texto de proposta nem mexe em mais nada do documento. O cronograma é o que já está
    cadastrado nesta proposta — esta ferramenta não inventa atividades nem datas.
  DESC

  def initialize(proposal:)
    super()
    @proposal = proposal
  end

  def execute
    attachment = latest_docx
    return { error: "Não encontrei um arquivo .docx anexado nesta conversa pra inserir o cronograma." }.to_json unless attachment

    pricing = @proposal.project_pricing
    return { error: "Esta proposta ainda não tem precificação — não dá pra montar o cronograma." }.to_json unless pricing

    if pricing.schedule_items.none?
      SuggestScheduleJob.perform_later(@proposal.id)
      return { aviso: "Esta proposta ainda não tem cronograma. Estou montando uma sugestão em segundo plano — " \
        "peça pra inserir de novo em instantes, ou monte o cronograma na Tela de Precificação." }.to_json
    end

    default_missing_dates!(pricing)
    schedules = build_schedules(pricing)
    return { error: "O cronograma desta proposta não tem data de início definida — informe na Tela de Precificação e tente de novo." }.to_json if schedules.empty?

    bytes = ProposalDocxFiller.new(nil).insert_schedule_section(attachment.blob.download, schedules: schedules)
    filename = "#{attachment.blob.filename.to_s.sub(/\.docx\z/i, '')}_com_Cronograma.docx"

    @proposal.generated_documents.attach(
      io: StringIO.new(bytes), filename: filename,
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      metadata: { kind: "revised_with_schedule", version: @proposal.version, description: "Documento revisado + cronograma" }
    )

    {
      success: true, version: @proposal.version, filenames: [ filename ],
      message: "Inseri a seção de cronograma (tabela + infográfico) no seu documento, logo depois de \"PRAZO DE EXECUÇÃO\". " \
        "Baixe abaixo — o resto do documento não foi tocado."
    }.to_json
  rescue ProposalDocxFiller::SectionAnchorError => e
    { error: e.message }.to_json
  rescue StandardError => e
    Rails.logger.error("InsertScheduleSectionTool falhou pra proposal #{@proposal.id}: #{e.class} #{e.message}")
    { error: "Não consegui inserir o cronograma no documento agora." }.to_json
  end

  private
    # Mesmo princípio de "só o mais recente conta" de LearnFromRevisedProposalTool#latest_attachment,
    # restrito a .docx (KMZ e PDF não servem aqui).
    def latest_docx
      @proposal.conversation.messages.flat_map(&:attachments)
        .select { |attachment| attachment.blob.filename.to_s.downcase.end_with?(".docx") }
        .last
    end

    # Gêmeo de GenerateProposalDocumentTool#default_missing_schedule_dates! (mesma regra
    # determinística: início do mês que vem pra tipo com itens mas sem data — CLAUDE.md seção 8).
    def default_missing_dates!(pricing)
      presumed = Date.current.next_month.beginning_of_month
      if pricing.schedule_items.exists?(schedule_type: "servico") && pricing.schedule_papyrus_start_date.blank?
        pricing.update!(schedule_papyrus_start_date: presumed)
      end
      return unless pricing.schedule_items.exists?(schedule_type: "implantacao") && pricing.schedule_empreendimento_start_date.blank?

      pricing.update!(schedule_empreendimento_start_date: presumed)
    end

    # Gêmeo de GenerateProposalDocumentTool#build_schedules/#schedule_payload — lê os itens e as
    # datas direto do banco, só os tipos com itens E data.
    def build_schedules(pricing)
      {
        "servico" => schedule_payload(pricing, "servico", pricing.schedule_papyrus_start_date),
        "implantacao" => schedule_payload(pricing, "implantacao", pricing.schedule_empreendimento_start_date)
      }.compact
    end

    def schedule_payload(pricing, type, start_date)
      items = pricing.schedule_items.select { |item| item.schedule_type == type }
      return nil if items.empty? || start_date.blank?

      { start_date: start_date, items: items }
    end
end
