# Mensagem que o SISTEMA posta no chat (geração em segundo plano, busca do TR, reorganização pela
# planilha) — não foi a IA que escreveu. Sem a marca, ela voltava pra IA como fala dela, e a IA
# aprendia que "gerar" é escrever "Gerado o arquivo…" sem chamar a ferramenta (2026-10, conversa 34:
# anunciou um Rev.03 que nunca existiu). LlmHistoryTrimming reescreve como aviso do sistema.
class AddSystemNoticeToMessages < ActiveRecord::Migration[8.1]
  PREFIXES = [ "Gerado o arquivo", "Gerados 2 arquivos", "Não consegui gerar a proposta:", "Reorganizei a precificação",
               "Não encontrei uma lista de preços", "Não consegui reorganizar", "Procurei o Termo de Referência",
               "Não tenho onde procurar o TR", "Ainda não sei qual estudo" ].freeze

  def up
    add_column :messages, :system_notice, :boolean, null: false, default: false

    # As que já existem: começam com um dos textos do sistema e vêm logo depois de uma tarefa
    # interna (a resposta da IA a uma ferramenta vem depois de uma mensagem "tool", não interna).
    candidates = select_rows(<<~SQL.squish)
      SELECT m.id FROM messages m
      WHERE m.role = 'assistant' AND m.internal = false
        AND (#{PREFIXES.map { |prefix| "m.content LIKE #{connection.quote("#{prefix}%")}" }.join(' OR ')})
        AND (SELECT p.internal FROM messages p WHERE p.conversation_id = m.conversation_id AND p.id < m.id ORDER BY p.id DESC LIMIT 1)
    SQL
    execute("UPDATE messages SET system_notice = true WHERE id IN (#{candidates.flatten.join(',')})") if candidates.any?
  end

  def down
    remove_column :messages, :system_notice
  end
end
