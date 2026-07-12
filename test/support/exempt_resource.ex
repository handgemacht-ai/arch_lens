defmodule ArchLens.TestSupport.ExemptResource do
  @moduledoc "Fixture: a resource that declares `privacy_exempt` with a reason instead of a `privacy` block."

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    extensions: [ArchLens.Privacy]

  privacy_exempt do
    reason("legacy import table, no PII collected")
  end

  attributes do
    uuid_primary_key :id
  end
end
