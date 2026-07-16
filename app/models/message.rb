class Message < ApplicationRecord
  acts_as_message chat: :conversation
  has_many_attached :attachments
end
