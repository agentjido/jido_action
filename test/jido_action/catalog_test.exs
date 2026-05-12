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

  defmodule NotAnAction do
    def name, do: "not_an_action"
    def schema, do: []
    def run(params, _context), do: {:ok, params}
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

    test "rejects non-action modules" do
      assert {:error, _error} = Entry.from_module(NotAnAction)

      assert {:error, _error} =
               Entry.new(id: "fake", module: NotAnAction, name: "not_an_action")
    end

    test "normalizes aliases before applying module overrides" do
      assert {:ok, entry} =
               Entry.from_module(SearchUsers,
                 vsn: "2.0.0",
                 schema:
                   Zoi.object(%{
                     override: Zoi.string(description: "Override value")
                   })
               )

      assert entry.version == "2.0.0"
      assert entry.id == "#{inspect(SearchUsers)}:search_users@2.0.0"
      assert Map.has_key?(entry.input_schema["properties"], "override")
      refute Map.has_key?(entry.input_schema["properties"], "query")
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
  end

  describe "Query and Hit" do
    test "constructs plain query and hit values" do
      assert {:ok, query} = Query.new("users")
      assert query.text == "users"
      assert query.visibility == [:public]
      assert query.limit == 10

      assert {:error, _error} = Query.new(visibility: [:private])

      entry = Entry.new!(id: "entry", module: SearchUsers, name: "search_users")
      assert {:ok, hit} = Hit.new(entry: entry, score: 1.5, matches: %{name: 1.5})
      assert hit.entry == entry
      assert hit.score == 1.5
    end
  end
end
