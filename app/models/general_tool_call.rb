class GeneralToolCall < ApplicationRecord
  acts_as_tool_call message: :general_message
end
