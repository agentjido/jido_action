defmodule Jido.Action.CatalogTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Catalog
  alias Jido.Action.Catalog.Entry
  alias Jido.Action.Catalog.Hit
  alias Jido.Action.Catalog.Query

  defmodule SearchUsers do
    use Jido.Action,
      name: "search_users",
      description: "Search user accounts by name or email",
      category: "users",
      tags: ["users", "search"],
      vsn: "1.0.0",
      schema:
        Zoi.object(%{
          query: Zoi.string(description: "Search query"),
          limit: Zoi.integer(description: "Maximum result count") |> Zoi.default(10)
        }),
      output_schema:
        Zoi.object(%{
          users: Zoi.list(Zoi.map(), description: "Matched users")
        })

    @impl true
    def run(_params, _context), do: {:ok, %{users: []}}
  end

  defmodule SendEmail do
    use Jido.Action,
      name: "send_email",
      description: "Send an email message",
      category: "messaging",
      tags: ["email", "message"],
      schema: [
        to: [type: :string, required: true, doc: "Recipient address"],
        subject: [type: :string, required: true, doc: "Message subject"]
      ]

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule CompatibleTool do
    def name, do: "compatible_tool"
    def schema, do: []
    def run(params, _context), do: {:ok, params}
  end

  defmodule MissingRun do
    def name, do: "missing_run"
    def schema, do: []
  end

  describe "Entry" do
    test "builds normalized metadata from an action module" do
      assert {:ok, entry} =
               Entry.from_module(SearchUsers,
                 namespace: "accounts",
                 capabilities: ["lookup"],
                 read_only?: true,
                 keywords: ["people"]
               )

      assert entry.module == SearchUsers
      assert entry.name == "search_users"
      assert entry.description == "Search user accounts by name or email"
      assert entry.category == "users"
      assert entry.tags == ["users", "search"]
      assert entry.version == "1.0.0"
      assert entry.namespace == "accounts"
      assert entry.capabilities == ["lookup"]
      assert entry.read_only? == true
      assert entry.keywords == ["people"]
      assert entry.schema_kind == :zoi
      assert entry.id == "#{inspect(SearchUsers)}:search_users@1.0.0"
      assert entry.input_schema["type"] == "object"
      assert entry.input_schema["additionalProperties"] == false
      assert entry.output_schema["type"] == "object"
      assert entry.output_schema["additionalProperties"] == false
    end

    test "supports raw attribute construction" do
      assert {:ok, entry} =
               Entry.new(%{
                 id: "custom",
                 module: SendEmail,
                 name: "custom_email",
                 visibility: :internal,
                 risk: :medium,
                 metadata: %{owner: "ops"}
               })

      assert entry.id == "custom"
      assert entry.visibility == :internal
      assert entry.risk == :medium
      assert entry.metadata == %{owner: "ops"}
    end

    test "supports known string keys and string enum values" do
      assert {:ok, entry} =
               Entry.new(%{
                 "id" => "custom",
                 "module" => inspect(SendEmail),
                 "name" => "custom_email",
                 "visibility" => "internal",
                 "risk" => "medium",
                 "source" => "runtime"
               })

      assert entry.id == "custom"
      assert entry.module == SendEmail
      assert entry.visibility == :internal
      assert entry.risk == :medium
      assert entry.source == :runtime
    end

    test "supports local action-compatible modules" do
      assert {:ok, entry} = Entry.from_module(CompatibleTool)

      assert entry.module == CompatibleTool
      assert entry.name == "compatible_tool"
      assert entry.schema_kind == :empty
    end

    test "rejects incompatible local modules" do
      assert {:error, _error} = Entry.from_module(MissingRun)

      assert {:error, _error} =
               Entry.new(id: "fake", module: MissingRun, name: "missing_run")
    end

    test "normalizes aliases before applying module overrides" do
      assert {:ok, entry} =
               Entry.from_module(SearchUsers,
                 vsn: "2.0.0",
                 schema: [
                   override: [
                     type: :string,
                     required: true,
                     doc: "Override value"
                   ]
                 ]
               )

      assert entry.version == "2.0.0"
      assert entry.id == "#{inspect(SearchUsers)}:search_users@2.0.0"
      assert entry.schema_kind == :nimble
      assert Map.has_key?(entry.input_schema["properties"], "override")
      refute Map.has_key?(entry.input_schema["properties"], "query")
    end

    test "rejects invalid module override attrs" do
      assert {:error, _error} = Entry.from_module(SearchUsers, :bad_overrides)
      assert {:error, _error} = Entry.from_module(SearchUsers, [:bad_override])
    end

    test "rejects unsupported enum values" do
      assert {:error, _error} =
               Entry.new(
                 id: "custom",
                 module: SendEmail,
                 name: "custom_email",
                 visibility: :private
               )

      assert {:error, _error} =
               Entry.new(
                 id: "custom",
                 module: SendEmail,
                 name: "custom_email",
                 risk: :critical
               )

      assert {:error, _error} =
               Entry.new(
                 id: "custom",
                 module: SendEmail,
                 name: "custom_email",
                 source: :remote
               )
    end
  end

  describe "Catalog" do
    test "builds from existing action modules and lists entries deterministically" do
      assert {:ok, catalog} =
               Catalog.from_modules([SendEmail, SearchUsers],
                 id: "app-actions",
                 name: "App Actions"
               )

      assert catalog.id == "app-actions"
      assert catalog.name == "App Actions"
      assert Enum.map(Catalog.list(catalog), & &1.name) == ["search_users", "send_email"]
    end

    test "validates constructor entries" do
      entry_attrs = %{
        id: "email",
        module: SendEmail,
        name: "send_email"
      }

      assert {:ok, catalog} =
               Catalog.new(id: "test", entries: %{"ignored-key" => entry_attrs})

      assert Map.keys(catalog.entries) == ["email"]
      assert [%Entry{name: "send_email"}] = Catalog.list(catalog)

      assert {:error, _error} =
               Catalog.new(id: "test", entries: %{"invalid" => "not-entry"})
    end

    test "registers, fetches, and unregisters entries by id or name" do
      catalog =
        Catalog.new!(id: "test")
        |> Catalog.register!(SearchUsers)
        |> Catalog.register!(SendEmail)

      assert {:ok, search_entry} =
               Catalog.fetch(catalog, "#{inspect(SearchUsers)}:search_users@1.0.0")

      assert search_entry.name == "search_users"

      assert {:ok, email_entry} = Catalog.fetch(catalog, "send_email")
      assert email_entry.module == SendEmail

      assert {:ok, updated} = Catalog.unregister(catalog, "send_email")
      assert {:error, :not_found} = Catalog.fetch(updated, "send_email")
      assert {:ok, _entry} = Catalog.fetch(updated, "search_users")
    end

    test "registers prebuilt entries with overrides" do
      entry = Entry.new!(id: "email", module: SendEmail, name: "send_email")

      catalog =
        Catalog.new!(id: "test")
        |> Catalog.register!(entry, visibility: :internal, risk: :medium)

      assert {:ok, updated_entry} = Catalog.fetch(catalog, "email")
      assert updated_entry.visibility == :internal
      assert updated_entry.risk == :medium
    end

    test "registers prebuilt entries with serialized map overrides" do
      entry = Entry.new!(id: "email", module: SendEmail, name: "send_email")

      catalog =
        Catalog.new!(id: "test")
        |> Catalog.register!(entry, %{
          "id" => "email-v2",
          "visibility" => "internal",
          "risk" => "medium",
          "source" => "runtime",
          "vsn" => "2.0.0",
          "schema" => [
            body: [
              type: :string,
              required: true,
              doc: "Message body"
            ]
          ]
        })

      assert {:error, :not_found} = Catalog.fetch(catalog, "email")
      assert {:ok, updated_entry} = Catalog.fetch(catalog, "email-v2")
      assert updated_entry.visibility == :internal
      assert updated_entry.risk == :medium
      assert updated_entry.source == :runtime
      assert updated_entry.version == "2.0.0"
      assert updated_entry.schema_kind == :nimble
      assert Map.has_key?(updated_entry.input_schema["properties"], "body")
    end

    test "refreshes derived metadata when registering prebuilt entries with overrides" do
      entry = Entry.from_module!(SearchUsers)
      updated_id = "#{inspect(SearchUsers)}:search_users@2.0.0"

      catalog =
        Catalog.new!(id: "test")
        |> Catalog.register!(entry,
          vsn: "2.0.0",
          schema: [
            override: [
              type: :string,
              required: true,
              doc: "Override value"
            ]
          ]
        )

      assert {:error, :not_found} = Catalog.fetch(catalog, entry.id)
      assert {:ok, updated_entry} = Catalog.fetch(catalog, updated_id)
      assert updated_entry.version == "2.0.0"
      assert updated_entry.schema_kind == :nimble
      assert Map.has_key?(updated_entry.input_schema["properties"], "override")
      refute Map.has_key?(updated_entry.input_schema["properties"], "query")
    end

    test "preserves custom entry ids when registering prebuilt entries with overrides" do
      entry =
        Entry.new!(
          id: "custom-email",
          module: SendEmail,
          name: "send_email",
          version: "1.0.0"
        )

      catalog =
        Catalog.new!(id: "test")
        |> Catalog.register!(entry, vsn: "2.0.0")

      assert {:ok, updated_entry} = Catalog.fetch(catalog, "custom-email")
      assert updated_entry.id == "custom-email"
      assert updated_entry.version == "2.0.0"
    end

    test "reports ambiguous name lookups" do
      first = Entry.new!(id: "first", module: SearchUsers, name: "duplicate")
      second = Entry.new!(id: "second", module: SendEmail, name: "duplicate")

      catalog =
        Catalog.new!(id: "test")
        |> Catalog.register!(first)
        |> Catalog.register!(second)

      assert {:error, {:ambiguous, "duplicate", ids}} = Catalog.fetch(catalog, "duplicate")
      assert Enum.sort(ids) == ["first", "second"]
    end

    test "searches entries with lexical ranking and filters" do
      catalog =
        Catalog.new!(id: "test")
        |> Catalog.register!(SearchUsers,
          namespace: "accounts",
          capabilities: ["lookup"],
          read_only?: true
        )
        |> Catalog.register!(SendEmail,
          namespace: "messaging",
          capabilities: ["notify"],
          risk: :medium
        )

      assert {:ok, [hit | _]} = Catalog.search(catalog, text: "email")
      assert %Hit{} = hit
      assert hit.entry.name == "send_email"
      assert hit.score > 0
      assert map_size(hit.matches) > 0

      assert {:ok, [accounts_hit]} =
               Catalog.search(catalog,
                 namespace: "accounts",
                 tags: ["users"],
                 capabilities: ["lookup"],
                 filters: %{read_only?: true}
               )

      assert accounts_hit.entry.name == "search_users"

      assert {:ok, [risk_hit]} = Catalog.search(catalog, filters: %{"risk" => "medium"})
      assert risk_hit.entry.name == "send_email"

      assert {:ok, []} = Catalog.search(catalog, filters: %{"unknown" => nil})
    end

    test "phrase matches are not penalized below scattered token matches" do
      phrase_entry =
        Entry.new!(
          id: "phrase",
          module: CompatibleTool,
          name: "phrase",
          description: "Delete user account"
        )

      scattered_entry =
        Entry.new!(
          id: "scattered",
          module: CompatibleTool,
          name: "scattered",
          description: "Delete stale records from the user table and archive the account"
        )

      catalog =
        Catalog.new!(id: "test")
        |> Catalog.register!(phrase_entry)
        |> Catalog.register!(scattered_entry)

      assert {:ok, [first_hit | _]} = Catalog.search(catalog, "delete user account")
      assert first_hit.entry.id == "phrase"
    end

    test "search defaults to public entries and can include internal entries" do
      catalog =
        Catalog.new!(id: "test")
        |> Catalog.register!(SearchUsers)
        |> Catalog.register!(SendEmail, visibility: :internal)

      assert {:ok, hits} = Catalog.search(catalog, %{})
      assert Enum.map(hits, & &1.entry.name) == ["search_users"]

      assert {:ok, hits} = Catalog.search(catalog, visibility: [:public, :internal])
      assert Enum.map(hits, & &1.entry.name) == ["search_users", "send_email"]
    end

    test "filter-only search returns neutral hits without match metadata" do
      entry = %Entry{
        id: "expensive",
        module: CompatibleTool,
        name: "expensive",
        input_schema: %{"description" => "expensive schema"},
        output_schema: %{"description" => "expensive output"},
        tags: ["expensive"]
      }

      catalog = %Catalog{id: "test", entries: %{entry.id => entry}}

      assert {:ok, [hit]} = Catalog.search(catalog, tags: ["expensive"])
      assert hit.entry.id == "expensive"
      assert hit.score == 1.0
      assert hit.reason == nil
      assert hit.matches == %{}
    end

    test "empty visibility filter matches no entries" do
      catalog =
        Catalog.new!(id: "test")
        |> Catalog.register!(SearchUsers)
        |> Catalog.register!(SendEmail, visibility: :hidden)

      assert {:ok, []} = Catalog.search(catalog, visibility: [])
      assert {:ok, hits} = Catalog.search(catalog, visibility: [:hidden])
      assert Enum.map(hits, & &1.entry.name) == ["send_email"]
    end
  end

  describe "Query and Hit" do
    test "constructs plain query and hit values" do
      assert {:ok, query} = Query.new("users")
      assert query.text == "users"
      assert query.visibility == [:public]
      assert query.limit == 10

      assert {:error, _error} = Query.new(visibility: [:private])

      assert {:ok, query} = Query.new(%{"visibility" => ["public", "internal"]})
      assert query.visibility == [:public, :internal]

      entry = Entry.new!(id: "entry", module: SearchUsers, name: "search_users")
      assert {:ok, hit} = Hit.new(entry: entry, score: 1.5, matches: %{name: 1.5})
      assert hit.entry == entry
      assert hit.score == 1.5
    end
  end
end
