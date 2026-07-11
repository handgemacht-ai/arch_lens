defmodule ArchLens.TestSupport.DocumentedResource do
  @moduledoc """
  Stores contact submissions captured from the public marketing site.

  This second paragraph documents internal retention mechanics and must never be
  surfaced by the architecture summary — only the first paragraph is collected.
  """
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
    uuid_primary_key(:id)
  end
end
