# Prepara os anexos de uma conversa para irem à IA, contornando o teto de tamanho do provider.
#
# O Bedrock recusa documento acima de 4,5 MB ("The maximum document size is 4.5 MB") e a chamada
# inteira falha. Isso não é caso raro: TR em Word com fotos e plantas passa disso com facilidade
# — o ET_181 da Renova tem 8,2 MB para apenas ~31 mil caracteres de texto, ou seja, o peso é
# quase todo imagem que não muda em nada a análise do escopo.
#
# Em vez de deixar o processamento falhar, o texto do arquivo grande é extraído aqui (mesmo
# extrator do pipeline de RAG, que já lida com PDF, DOCX e .doc legado) e segue no corpo do
# prompt. Perde-se a leitura nativa do documento pelo modelo; ganha-se o processamento
# acontecer. Arquivos dentro do limite continuam indo como anexo, sem alteração.
class AttachmentPreparer
  # Margem sobre os 4,5 MB do provider: o arquivo é transportado em base64, que infla o
  # payload, e o limite reportado não deixa claro qual dos dois tamanhos ele mede.
  MAX_DOCUMENT_BYTES = 3.5.megabytes

  # Teto do texto extraído de UM arquivo. Um TR de 100 páginas dá ~200 mil caracteres e cabe
  # bem; o corte existe só para um anexo anômalo não estourar a janela de contexto sozinho.
  MAX_TEXT_CHARS = 400_000

  Result = Data.define(:attachments, :inline_text, :converted) do
    def converted? = converted.any?
  end

  def initialize(attachments)
    @attachments = Array(attachments)
  end

  def call
    small, large = @attachments.partition { |attachment| attachment.byte_size <= MAX_DOCUMENT_BYTES }
    return Result.new(attachments: small, inline_text: nil, converted: []) if large.empty?

    sections = large.filter_map { |attachment| section_for(attachment) }

    Result.new(
      attachments: small,
      inline_text: sections.any? ? sections.join("\n\n") : nil,
      converted: large.map { |attachment| attachment.filename.to_s }
    )
  end

  private

  def section_for(attachment)
    text = extract(attachment)

    # Falhar em silêncio aqui é pior do que não ter o arquivo: sem anexo E sem aviso, a IA
    # analisa o TR que não recebeu e responde com confiança sobre um documento que nunca viu.
    # Acontece de verdade em produção se faltar poppler-utils (PDF) ou libreoffice (.doc).
    return unreadable_notice(attachment) if text.blank?

    <<~TEXT
      --- CONTEÚDO DO ARQUIVO "#{attachment.filename}" (texto extraído; o arquivo original é
      grande demais para ser enviado inteiro, então imagens e diagramas dele não estão aqui) ---
      #{text.truncate(MAX_TEXT_CHARS)}
      --- FIM DE "#{attachment.filename}" ---
    TEXT
  end

  def unreadable_notice(attachment)
    Rails.logger.error("[AttachmentPreparer] #{attachment.filename} não pôde ser lido e ficará fora do prompt")

    "--- O arquivo \"#{attachment.filename}\" foi enviado pelo consultor mas o sistema não " \
    "conseguiu extrair o conteúdo dele. NÃO invente o que ele diz: avise o consultor de que " \
    "esse arquivo não pôde ser lido e peça outra versão (PDF ou DOCX). ---"
  end

  # O Rag::TextExtractor trabalha sobre um caminho no disco, então o blob é materializado num
  # arquivo temporário com a extensão original — é a extensão que decide o extrator usado.
  def extract(attachment)
    extension = File.extname(attachment.filename.to_s).presence || ".bin"

    Tempfile.create([ "anexo", extension ]) do |file|
      file.binmode
      attachment.download { |chunk| file.write(chunk) }
      file.flush

      result = Rag::TextExtractor.new(file.path, ocr: false).call
      # plain_text, não text: o extrator marca títulos com um caractere de controle que só
      # interessa ao chunker do RAG e que a API do provider rejeita.
      result.ok? ? result.plain_text : nil
    end
  rescue StandardError => e
    Rails.logger.error("[AttachmentPreparer] falha ao extrair #{attachment.filename}: #{e.class} #{e.message}")
    nil
  end
end
