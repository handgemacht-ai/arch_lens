defmodule ArchLens.TestSupport.ValidPrivacyResource do
  @moduledoc "Fixture: a resource that declares a valid `privacy` block."

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  privacy do
    data_category(:contact)
    retention("P30D")
    legal_basis(:consent)
  end

  attributes do
    uuid_primary_key :id
  end
end
