# frozen_string_literal: true

# Who is signed in, as Rails's authentication generator keeps it; Fixwire reads Current.user.
class Current < ActiveSupport::CurrentAttributes
  attribute :user
end
