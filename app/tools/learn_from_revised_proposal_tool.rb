# Deixa a IA PROPOR que a versão final de um documento — revisada manualmente por alguém da
# Papyrus e anexada nesta conversa — entre no acervo RAG como "voz da Papyrus" (CLAUDE.md seção
# 11.1). Casos reais: o consultor pega o rascunho que a IA gerou, reescreve/ajusta e produz a
# versão que realmente vai pro cliente — sem que isso passe por proposals#approve neste sistema
# (pode nunca ser re-subida aqui como "documento gerado"). Sem esta ferramenta, essa versão nunca
# chegaria ao índice, e a IA nunca aprenderia com o texto que a Papyrus de fato validou.
#
# Mesmo princípio de curadoria de RememberForFutureProposalsTool/KnowledgeNote: a ferramenta NÃO
# indexa na hora, só cria um registro PENDENTE e um card no chat — quem decide se aquilo vira
# "voz da Papyrus" é o consultor, clicando Guardar (HistoricalProposal#approve!). O acervo só vale
# porque tudo nele foi confirmado por gente; indexar direto faria uma versão qualquer (ou um
# anexo errado) voltar meses depois citada com a mesma autoridade de uma proposta real.
class LearnFromRevisedProposalTool < RubyLLM::Tool
  description <<~DESC
    Registra, para APROVAÇÃO do consultor, que um documento anexado NESTA conversa é a versão
    final revisada/pronta pra envio de uma proposta — pra entrar no acervo histórico da Papyrus
    como referência de escrita para propostas futuras.

    Use SOMENTE quando o consultor confirmar explicitamente que um anexo já enviado no chat é essa
    versão final (ex.: "essa é a versão que revisei, guarda pro acervo"). NÃO use por conta
    própria, sem essa confirmação, e não use para o ET, o TR do cliente ou qualquer documento que
    não seja uma proposta/versão final escrita ou revisada pela Papyrus.

    A informação NÃO entra no acervo na hora: vai para o consultor aprovar num card. Ao chamar
    esta ferramenta, diga ao consultor o que você propôs guardar e que ele precisa aprovar.
  DESC

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute
    attachment = latest_attachment
    return { error: "Não encontrei nenhum documento anexado nesta conversa para guardar." }.to_json unless attachment

    blob = attachment.blob
    checksum = "blob:#{blob.checksum}"
    existing = HistoricalProposal.find_by(source_sha256: checksum)
    return already_registered(existing) if existing

    text = extract_text(blob)
    return { error: "Não consegui ler o conteúdo de \"#{blob.filename}\" — o arquivo pode estar sem texto (ex.: PDF escaneado)." }.to_json if text.blank?

    record = build_record(blob, checksum, text)
    @conversation.messages.create!(role: "assistant", content: { historical_proposal_id: record.id }.to_json)

    {
      success: true, historical_proposal_id: record.id, arquivo: blob.filename.to_s,
      status: "aguardando aprovação do consultor",
      instrucao: "Diga ao consultor que você propôs guardar esse arquivo no acervo e que ele precisa aprovar no card acima."
    }.to_json
  rescue StandardError => e
    Rails.logger.error("LearnFromRevisedProposalTool falhou para conversation #{@conversation.id}: #{e.class} #{e.message}")
    { error: "Não consegui registrar esse documento agora." }.to_json
  end

  private
    # Mesmo princípio de "só o mais recente conta" já usado em Message#stale_for_llm? — o anexo
    # que interessa é o que o consultor acabou de enviar, não um ET/TR antigo desta mesma
    # conversa. KMZ nunca é uma proposta, fica de fora.
    def latest_attachment
      @conversation.messages.flat_map(&:attachments).reject { |attachment| attachment.blob.metadata["kind"] == "kmz" }.last
    end

    def already_registered(record)
      status = { "pending" => "ainda aguardando aprovação", "approved" => "já guardado no acervo", "rejected" => "já foi descartado antes" }.fetch(record.review_status, record.review_status)
      { aviso: "Esse mesmo arquivo já foi registrado antes (#{status}); não criei um novo card." }.to_json
    end

    def extract_text(blob)
      Tempfile.create([ "revisao", File.extname(blob.filename.to_s) ]) do |file|
        file.binmode
        blob.download { |chunk| file.write(chunk) }
        file.flush

        result = Rag::TextExtractor.new(file.path).call
        result.ok? ? result.text : nil
      end
    end

    def build_record(blob, checksum, text)
      proposal = @conversation.proposal

      HistoricalProposal.create!(
        source_sha256: checksum,
        origin: "revisao_manual",
        conversation: @conversation,
        job_name: proposal&.docx_numero_proposta || @conversation.client_name,
        job_number: proposal&.docx_numero_proposta,
        client_name: @conversation.client_name,
        subject: @conversation.study_type&.name,
        source_path: "active_storage:#{blob.key}",
        relative_path: blob.filename.to_s,
        filename: blob.filename.to_s,
        chunker_version: Rag::Indexer::PIPELINE_VERSION,
        role: "proposta_papyrus",
        role_source: "consultor",
        status: "ok",
        review_status: "pending",
        pending_text: text,
        revision: proposal&.version,
        year: Date.current.year,
        superseded: false
      )
    end
end
