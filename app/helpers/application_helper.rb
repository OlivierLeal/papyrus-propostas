module ApplicationHelper
  ICON_USUARIOS = "M10 8a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM3.465 14.493a1.23 1.23 0 0 0 .41 1.412A9.957 9.957 0 0 0 10 18c2.31 0 4.438-.784 6.131-2.1.43-.333.604-.903.408-1.41a7.002 7.002 0 0 0-13.074.003Z"
  ICON_CONFIGURACOES = "M8.34 1.804A1 1 0 0 1 9.32 1h1.36a1 1 0 0 1 .98.804l.295 1.473c.497.144.971.342 1.416.587l1.25-.834a1 1 0 0 1 1.262.125l.962.962a1 1 0 0 1 .125 1.262l-.834 1.25c.245.445.443.919.587 1.416l1.473.294a1 1 0 0 1 .804.98v1.361a1 1 0 0 1-.804.98l-1.473.295a6.95 6.95 0 0 1-.587 1.416l.834 1.25a1 1 0 0 1-.125 1.262l-.962.962a1 1 0 0 1-1.262.125l-1.25-.834a6.953 6.953 0 0 1-1.416.587l-.294 1.473a1 1 0 0 1-.98.804H9.32a1 1 0 0 1-.98-.804l-.295-1.473a6.957 6.957 0 0 1-1.416-.587l-1.25.834a1 1 0 0 1-1.262-.125l-.962-.962a1 1 0 0 1-.125-1.262l.834-1.25a6.957 6.957 0 0 1-.587-1.416l-1.473-.294A1 1 0 0 1 1 10.68V9.32a1 1 0 0 1 .804-.98l1.473-.295c.144-.497.342-.971.587-1.416l-.834-1.25a1 1 0 0 1 .125-1.262l.962-.962a1 1 0 0 1 1.262-.125l1.25.834a6.957 6.957 0 0 1 1.416-.587l.295-1.473ZM13 10a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
  ICON_PROPOSTAS = "M4 4a2 2 0 0 1 2-2h4.586A2 2 0 0 1 12 2.586L15.414 6A2 2 0 0 1 16 7.414V16a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V4Zm2.75 6a.75.75 0 0 0 0 1.5h6.5a.75.75 0 0 0 0-1.5h-6.5Zm0 3a.75.75 0 0 0 0 1.5h6.5a.75.75 0 0 0 0-1.5h-6.5Z"

  # Notificações de flash (shared/_flash.html.erb), no estilo dos "types" do Ant Design Notification.
  FLASH_TYPES = {
    "notice"  => { title: "Sucesso",    color: "success", icon: :check },
    "success" => { title: "Sucesso",    color: "success", icon: :check },
    "alert"   => { title: "Erro",       color: "error",   icon: :error },
    "error"   => { title: "Erro",       color: "error",   icon: :error },
    "warning" => { title: "Atenção",    color: "warning", icon: :warning },
    "info"    => { title: "Informação", color: "info",    icon: :info }
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
      sidebar_menu_link("Configurações", settings_root_path, ICON_CONFIGURACOES, active: request.path.start_with?("/settings")),
      sidebar_menu_link("Usuários", users_path, ICON_USUARIOS)
    ])
  end

  private
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
