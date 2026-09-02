class GeneralMessage < ApplicationRecord
  acts_as_message chat: :general_chat, tool_calls: :general_tool_calls

  # Mesmo motivo de Message#hide_tool_result! — o JSON cru de uma tool call (search_historical_
  # archive, search_legal_norms) nasce com role "tool" e não deve virar bolha própria no chat.
  before_save :hide_tool_result!

  private
    def hide_tool_result!
      self.internal = true if role == "tool"
    end
end
