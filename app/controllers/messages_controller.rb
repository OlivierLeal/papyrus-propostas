class MessagesController < ApplicationController
  before_action :set_conversation

  def create
    unless @conversation.status.in?(%w[reviewing pricing completed])
      redirect_to @conversation, alert: "Aguarde o processamento terminar antes de continuar a conversa."
      return
    end

    content = params[:content].to_s.strip
    documents = Array(params[:documents]).reject(&:blank?)
    kmz, complementary_documents = documents.partition { |document| kmz_filename?(document) }

    if content.present? || documents.any?
      message = @conversation.create_user_message(content.presence || default_content(kmz, complementary_documents))
      complementary_documents.each { |document| attach_with_kind(message, document, "complementary") }
      kmz.each { |document| attach_with_kind(message, document, "kmz") }

      # Sem isso, quem manda a mensagem só a vê porque a página inteira recarrega — outras abas
      # (ou outro consultor olhando a mesma proposta) nunca recebem essa mensagem via WebSocket,
      # só a resposta da IA depois (que o RespondToMessageJob transmite).
      @conversation.broadcast_render_to @conversation,
        partial: "conversations/user_message_broadcast", locals: { message: message }

      # KMZ enviado a qualquer momento da conversa (2026-09, pedido do consultor: proposta criada
      # sem KMZ no setup, depois ele quer jogar o arquivo no chat e ter o mapa/análise geoespacial
      # do mesmo jeito) — antes, ProcessKmzJob só era enfileirado por ConversationsController#create,
      # uma vez só, no setup. attachment_of_kind("kmz")/ProcessKmzJob não se importam com QUANDO o
      # anexo chegou, só que ele existe — reaproveita o job inteiro, sem duplicar lógica de
      # geoprocessamento aqui. RespondToMessageJob roda em paralelo com o job (que processa em
      # background e pode levar alguns segundos) — a resposta da IA deste turno pode não ter ainda
      # o mapa/achados; eles ficam disponíveis pro turno seguinte (mesmo padrão de "gere de novo em
      # instantes" já usado pro cronograma).
      ProcessKmzJob.perform_later(@conversation.id) if kmz.any?

      RespondToMessageJob.perform_later(@conversation.id)
    end

    # turbo_stream (padrão dos forms com Turbo habilitado) só devolve o composer limpo — a
    # mensagem em si já chega pra esta mesma aba via broadcast acima (WebSocket), sem precisar
    # navegar a página inteira de novo. html continua existindo como fallback (JS desabilitado,
    # ou os testes que ainda fazem POST simples).
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @conversation }
    end
  end

  private
    def set_conversation
      @conversation = Conversation.find(params[:conversation_id])
    end

    def default_content(kmz, complementary_documents)
      parts = []
      parts << "KMZ: #{kmz.map(&:original_filename).join(', ')}" if kmz.any?
      parts << "Documento(s) complementar(es): #{complementary_documents.map(&:original_filename).join(', ')}" if complementary_documents.any?
      "#{parts.join(' — ')} enviado(s)."
    end
end
