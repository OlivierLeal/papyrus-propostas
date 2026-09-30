# Preenche uma planilha do cliente (PPU, DFP, formação de preço…) anexada na conversa, a partir da
# precificação da proposta. Só enfileira FillClientSpreadsheetJob: ler a planilha é chamada de IA e
# nunca roda síncrona dentro de uma tool call (CLAUDE.md seção 8). O resultado chega como card no
# chat, com o arquivo e o que foi preenchido.
class FillClientSpreadsheetTool < RubyLLM::Tool
  description <<~DESC
    Preenche uma planilha que o CLIENTE mandou pra ser devolvida junto com a proposta (planilha de
    preços unitários/PPU, DFP/formação de preço, BDI, encargos, quadro de equipe, dados cadastrais,
    checklist…), usando os dados desta proposta. Use quando o consultor pedir pra preencher (ou
    preencher de novo) uma planilha. A geração da proposta com parte comercial já preenche sozinha
    as planilhas anexadas — não chame esta ferramenta só por estar gerando a proposta.
    Planilha que é só material de referência é identificada pelo sistema e não é preenchida; se o
    consultor insistir, chame de novo que ela é tratada como formulário.

    Roda em segundo plano: diga ao consultor que o resultado aparece aqui no chat em instantes,
    com o arquivo pronto e o que foi preenchido. Você não escreve valores: o sistema calcula tudo
    a partir da Tela de Precificação.
  DESC

  param :arquivo, desc: "Nome (ou parte do nome) da planilha anexada, se houver mais de uma. Vazio = a mais recente.", required: false
  param :orientacao, desc: "Orientação do consultor pra este preenchimento (ex.: \"o item 3 é só da campanha offshore\")", required: false

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute(arquivo: nil, orientacao: nil)
    pricing = @conversation.proposal&.project_pricing
    return { error: "Esta proposta ainda não tem precificação. Abra a Tela de Precificação antes de preencher a planilha." }.to_json unless pricing

    attachment = find_spreadsheet(arquivo)
    return { error: "Não encontrei planilha .xlsx/.xlsm anexada nesta conversa#{" com o nome \"#{arquivo}\"" if arquivo.present?}. Planilha .xls antiga: peça ao consultor pra salvar como .xlsx." }.to_json unless attachment

    if @conversation.spreadsheet_fills.where(source_blob_id: attachment.blob_id, status: "processing").exists?
      return { aviso: "Essa planilha já está sendo preenchida; o resultado aparece no chat em instantes." }.to_json
    end

    # Pedido explícito do consultor vence a classificação anterior de "só referência".
    forced = @conversation.spreadsheet_fills.where(source_blob_id: attachment.blob_id).last&.not_applicable? || false
    fill = @conversation.spreadsheet_fills.create!(source_blob: attachment.blob, instructions: orientacao.presence, forced: forced)
    FillClientSpreadsheetJob.perform_later(fill.id)
    { success: true, planilha: attachment.filename.to_s,
      status: "Preenchendo em segundo plano; o resultado aparece no chat em instantes, com o arquivo e o que foi preenchido." }.to_json
  end

  private

  def find_spreadsheet(name)
    candidates = SpreadsheetFill.client_spreadsheets(@conversation)
    candidates = candidates.select { |attachment| I18n.transliterate(attachment.filename.to_s.downcase).include?(I18n.transliterate(name.to_s.downcase.strip)) } if name.present?
    candidates.last
  end
end
