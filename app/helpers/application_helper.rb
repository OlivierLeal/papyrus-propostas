module ApplicationHelper
  # A IA responde em markdown (negrito, listas, títulos); renderizamos como HTML de verdade
  # em vez de texto cru com asteriscos. filter_html descarta qualquer HTML que vier embutido
  # na resposta da IA, e sanitize abaixo é a segunda camada de proteção contra XSS.
  MARKDOWN_RENDERER = Redcarpet::Markdown.new(
    Redcarpet::Render::HTML.new(filter_html: true,
      link_attributes: { rel: "noopener noreferrer", target: "_blank" }),
    autolink: true, fenced_code_blocks: true, tables: true, strikethrough: true, no_intra_emphasis: true
  ).freeze

  MARKDOWN_ALLOWED_TAGS = %w[p br strong em ul ol li h1 h2 h3 h4 h5 h6 a code pre blockquote table thead tbody tr td th hr del].freeze
  MARKDOWN_ALLOWED_ATTRIBUTES = %w[href rel target].freeze

  # findings: achados desta conversa que o texto cita por código (ver Message#cited_findings).
  # Cada "[F12]" vira um botão que abre o popover com o trecho e o documento de origem — é assim
  # que o consultor consegue perguntar "por que você concluiu isso?" sem sair do chat.
  #
  # A substituição acontece DEPOIS do sanitize de propósito: o token é texto puro e atravessa o
  # Redcarpet e o sanitize intacto, e a marcação do chip é montada aqui no servidor, escapando o
  # que veio da IA. Código sem achado correspondente é REMOVIDO — deixá-lo visível daria à
  # afirmação uma aparência de fonte que ela não tem.
  def render_markdown(text, findings: nil)
    html = sanitize(MARKDOWN_RENDERER.render(normalize_markdown_lists(text.to_s)),
      tags: MARKDOWN_ALLOWED_TAGS, attributes: MARKDOWN_ALLOWED_ATTRIBUTES)

    by_id = Array(findings).index_by(&:id)
    html.gsub(Message::CITATION_PATTERN) { citation_chip(by_id[Regexp.last_match(1).to_i]) }.html_safe
  end

  # Os popovers dos achados citados numa mensagem. Ficam fora do elemento animado pelo typewriter
  # (ver conversations/_message.html.erb).
  def render_citation_popovers(findings)
    safe_join(Array(findings).map { |finding| citation_popover(finding) })
  end

  ICON_USUARIOS = "M10 8a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM3.465 14.493a1.23 1.23 0 0 0 .41 1.412A9.957 9.957 0 0 0 10 18c2.31 0 4.438-.784 6.131-2.1.43-.333.604-.903.408-1.41a7.002 7.002 0 0 0-13.074.003Z"
  ICON_CONFIGURACOES = "M8.34 1.804A1 1 0 0 1 9.32 1h1.36a1 1 0 0 1 .98.804l.295 1.473c.497.144.971.342 1.416.587l1.25-.834a1 1 0 0 1 1.262.125l.962.962a1 1 0 0 1 .125 1.262l-.834 1.25c.245.445.443.919.587 1.416l1.473.294a1 1 0 0 1 .804.98v1.361a1 1 0 0 1-.804.98l-1.473.295a6.95 6.95 0 0 1-.587 1.416l.834 1.25a1 1 0 0 1-.125 1.262l-.962.962a1 1 0 0 1-1.262.125l-1.25-.834a6.953 6.953 0 0 1-1.416.587l-.294 1.473a1 1 0 0 1-.98.804H9.32a1 1 0 0 1-.98-.804l-.295-1.473a6.957 6.957 0 0 1-1.416-.587l-1.25.834a1 1 0 0 1-1.262-.125l-.962-.962a1 1 0 0 1-.125-1.262l.834-1.25a6.957 6.957 0 0 1-.587-1.416l-1.473-.294A1 1 0 0 1 1 10.68V9.32a1 1 0 0 1 .804-.98l1.473-.295c.144-.497.342-.971.587-1.416l-.834-1.25a1 1 0 0 1 .125-1.262l.962-.962a1 1 0 0 1 1.262-.125l1.25.834a6.957 6.957 0 0 1 1.416-.587l.295-1.473ZM13 10a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
  ICON_PROPOSTAS = "M4 4a2 2 0 0 1 2-2h4.586A2 2 0 0 1 12 2.586L15.414 6A2 2 0 0 1 16 7.414V16a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V4Zm2.75 6a.75.75 0 0 0 0 1.5h6.5a.75.75 0 0 0 0-1.5h-6.5Zm0 3a.75.75 0 0 0 0 1.5h6.5a.75.75 0 0 0 0-1.5h-6.5Z"
  ICON_TIRA_DUVIDAS = "M10 3c-4.31 0-8 3.033-8 7 0 2.024.978 3.825 2.499 5.085a3.478 3.478 0 0 1-.522 1.756.75.75 0 0 0 .584 1.143 5.976 5.976 0 0 0 3.936-1.108c.487.082.99.124 1.503.124 4.31 0 8-3.033 8-7s-3.69-7-8-7Z"

  # Notificações de flash (shared/_flash.html.erb), no estilo dos "types" do Ant Design Notification.
  # `text_class`/`bar_class` guardam o nome de classe completo em vez da cor solta: o Tailwind
  # varre o código-fonte procurando classes literais e não enxerga nomes montados por interpolação.
  FLASH_TYPES = {
    "notice"  => { title: "Sucesso",    text_class: "text-success", bar_class: "bg-success", icon: :check },
    "success" => { title: "Sucesso",    text_class: "text-success", bar_class: "bg-success", icon: :check },
    "alert"   => { title: "Erro",       text_class: "text-error",   bar_class: "bg-error",   icon: :error },
    "error"   => { title: "Erro",       text_class: "text-error",   bar_class: "bg-error",   icon: :error },
    "warning" => { title: "Atenção",    text_class: "text-warning", bar_class: "bg-warning", icon: :warning },
    "info"    => { title: "Informação", text_class: "text-info",    bar_class: "bg-info",    icon: :info }
  }.freeze

  FLASH_ICON_PATHS = {
    check: "M16.704 4.153a.75.75 0 0 1 .143 1.052l-8 10.5a.75.75 0 0 1-1.127.075l-4.5-4.5a.75.75 0 0 1 1.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 0 1 1.05-.143Z",
    error: "M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16ZM8.28 7.22a.75.75 0 0 0-1.06 1.06L8.94 10l-1.72 1.72a.75.75 0 1 0 1.06 1.06L10 11.06l1.72 1.72a.75.75 0 1 0 1.06-1.06L11.06 10l1.72-1.72a.75.75 0 0 0-1.06-1.06L10 8.94 8.28 7.22Z",
    warning: "M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495ZM10 6a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 10 6Zm0 8a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z",
    info: "M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0Zm-7-4a1 1 0 1 1-2 0 1 1 0 0 1 2 0ZM9.75 9a.75.75 0 0 0 0 1.5h.25v3.25a.75.75 0 0 0 1.5 0v-4A.75.75 0 0 0 10.75 9h-1Z"
  }.freeze

  def flash_config(type)
    FLASH_TYPES.fetch(type.to_s, FLASH_TYPES["info"])
  end

  def render_sidebar_menu
    safe_join([
      sidebar_menu_link("Propostas", conversations_path, ICON_PROPOSTAS, active: request.path.start_with?("/conversations")),
      sidebar_menu_link("Tira-Dúvidas", general_chats_path, ICON_TIRA_DUVIDAS, active: request.path.start_with?("/general_chats")),
      sidebar_menu_link("Configurações", settings_root_path, ICON_CONFIGURACOES, active: request.path.start_with?("/settings")),
      sidebar_menu_link("Usuários", users_path, ICON_USUARIOS)
    ])
  end

  private
    # Sem achado correspondente, a marca simplesmente some do texto.
    def citation_chip(finding)
      return "" unless finding

      tag.button(finding.citation_code,
        type: "button",
        popovertarget: dom_id(finding, :citation),
        class: "align-baseline mx-0.5 px-1.5 rounded-selector bg-primary/10 text-primary text-[0.7rem] font-medium hover:bg-primary/20 cursor-pointer",
        title: "Ver de onde saiu esta informação")
    end

    def citation_popover(finding)
      tag.div(id: dom_id(finding, :citation), popover: "auto",
              class: "rounded-box border border-base-300 bg-base-100 shadow-lg p-4 max-w-md text-sm") do
        safe_join([
          tag.p("#{finding.citation_code} · #{finding.field_label}", class: "font-semibold text-base-content"),
          tag.p(finding.value, class: "text-base-content mt-1"),
          finding.excerpt.present? ? tag.blockquote("“#{finding.excerpt}”", class: "text-base-content/70 italic mt-2") : nil,
          tag.p("#{finding.nature_label} · #{finding.origin_label}", class: "text-xs text-base-content/50 mt-2")
        ].compact)
      end
    end

    # A IA raramente deixa uma linha em branco antes de uma lista (ex.: "**Título:**\n* item"),
    # e sem essa linha em branco o Redcarpet não reconhece o bloco como lista. Insere a linha em
    # branco só na transição pra dentro da lista, sem mexer no espaçamento entre os itens.
    def normalize_markdown_lists(text)
      list_marker = /\A\s*(?:[-*+]|\d+[.)])\s/
      lines = text.split("\n", -1)

      lines.each_with_index.flat_map do |line, index|
        previous_line = lines[index - 1] if index.positive?
        starts_new_list = line.match?(list_marker) && previous_line.present? && !previous_line.match?(list_marker)
        starts_new_list ? [ "", line ] : [ line ]
      end.join("\n")
    end

    def sidebar_menu_link(label, path, icon_path, active: current_page?(path))
      icone = tag.svg(xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 20 20", fill: "currentColor", class: "size-4 shrink-0") do
        tag.path(d: icon_path)
      end

      link_to path,
        class: "btn btn-ghost justify-start gap-2 w-full font-medium #{active ? "bg-primary/10 text-primary hover:bg-primary/10" : "text-base-content/70"}" do
        safe_join([ icone, label ])
      end
    end
end
