defmodule ArchLens.TestSupport.NoPersonalDataResource do
  @moduledoc "Fixture: a resource that declares `no_personal_data` instead of a `privacy` block."

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  no_personal_data do
  end

  attributes do
    uuid_primary_key :id
  end
end
