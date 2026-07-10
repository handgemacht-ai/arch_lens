defmodule ArchLens.TestSupport.UndeclaredResource do
  @moduledoc "Fixture: a resource that adds the extension but declares no posture."

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  attributes do
    uuid_primary_key :id
  end
end
