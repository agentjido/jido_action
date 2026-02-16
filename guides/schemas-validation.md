# Schemas & Validation

This guide covers the schema and validation system in Jido Action, including both NimbleOptions and Zoi schemas, how they're used for input/output validation, and how they power AI tool integration.

## Overview

Jido Action supports two schema backends:

| Backend | Best For | Returns |
|---------|----------|---------|
| **NimbleOptions** | Simple schemas, familiar Elixir patterns | `map()` |
| **Zoi** | Complex validation, transformations, refinements | `struct()` (converted to map) |

Both are fully supported and can be used interchangeably. The `Jido.Action.Schema` adapter provides a unified interface.

## NimbleOptions Schemas

NimbleOptions is the traditional choice for Elixir configuration validation. Use keyword lists to define your schema:

```elixir
defmodule MyApp.Actions.CreateUser do
  use Jido.Action,
    name: "create_user",
    description: "Creates a new user account",
    schema: [
      email: [
        type: :string,
        required: true,
        doc: "User's email address"
      ],
      name: [
        type: :string,
        required: true,
        doc: "User's full name"
      ],
      age: [
        type: :integer,
        required: false,
        doc: "User's age"
      ],
      role: [
        type: {:in, [:admin, :user, :guest]},
        default: :user,
        doc: "User role"
      ]
    ]

  @impl true
  def run(params, _context) do
    # params is a map: %{email: "...", name: "...", role: :user}
    {:ok, %{user_id: generate_id(), email: params.email}}
  end
  
  defp generate_id, do: Uniq.UUID.uuid7()
end
```

### Supported NimbleOptions Types

| Type | Description |
|------|-------------|
| `:string` | String values |
| `:integer` | Integer values |
| `:float` | Float values |
| `:boolean` | Boolean values |
| `:atom` | Atom values |
| `:map` | Map values |
| `{:in, [...]}` | Enumerated values |
| `{:list, type}` | List of specified type |
| `:keyword_list` | Keyword list |

### NimbleOptions Options

| Option | Description |
|--------|-------------|
| `required: true` | Field must be provided |
| `default: value` | Default value if not provided |
| `doc: "..."` | Documentation (appears in AI tool schemas) |
| `keys: [...]` | For nested keyword lists |

## Zoi Schemas (Recommended for Complex Validation)

Zoi provides advanced validation with built-in transformations and refinements. Use Zoi when you need:

- Input transformations (trim, case conversion)
- Custom validation logic
- Complex nested structures
- Type coercion

```elixir
defmodule MyApp.Actions.RegisterUser do
  use Jido.Action,
    name: "register_user",
    description: "Registers a new user with validation",
    schema: Zoi.object(%{
      email: Zoi.string()
             |> Zoi.trim()
             |> Zoi.to_downcase()
             |> Zoi.regex(Zoi.Regexes.email(), message: "Invalid email"),
      password: Zoi.string()
                |> Zoi.min(8, message: "Password must be at least 8 characters")
                |> Zoi.regex(~r/[A-Z]/, message: "Must contain uppercase")
                |> Zoi.regex(~r/[0-9]/, message: "Must contain digit"),
      name: Zoi.string() |> Zoi.trim() |> Zoi.min(1),
      age: Zoi.integer() |> Zoi.min(13) |> Zoi.max(120) |> Zoi.optional(),
      role: Zoi.enum([:user, :admin]) |> Zoi.default(:user)
    })

  @impl true
  def run(params, _context) do
    # params.email is already trimmed and lowercased
    # params.password passed all regex checks
    # params.age is nil if not provided
    {:ok, %{registered: true, email: params.email}}
  end
end
```

### Zoi Transformations

Transformations modify the input before validation:

```elixir
Zoi.string()
|> Zoi.trim()           # Remove whitespace
|> Zoi.to_downcase()    # Convert to lowercase
|> Zoi.to_upcase()      # Convert to uppercase
```

### Zoi Validators

```elixir
# String constraints
Zoi.string() |> Zoi.min(1) |> Zoi.max(100)
Zoi.string() |> Zoi.regex(~r/^[a-z]+$/)
Zoi.string() |> Zoi.email()  # Built-in email validation

# Number constraints
Zoi.integer() |> Zoi.min(0) |> Zoi.max(100)
Zoi.float() |> Zoi.positive()

# Enums
Zoi.enum([:low, :medium, :high])
```

### Custom Refinements

Add custom validation logic with `Zoi.refine/2`:

```elixir
schema: Zoi.object(%{
  password: Zoi.string()
            |> Zoi.min(8)
            |> Zoi.refine(fn password ->
              if String.contains?(password, ["password", "123456"]) do
                {:error, "Password is too common"}
              else
                :ok
              end
            end),
  confirm_password: Zoi.string()
})
|> Zoi.refine(fn params ->
  if params.password == params.confirm_password do
    :ok
  else
    {:error, "Passwords do not match"}
  end
end)
```

### Nested Objects

```elixir
schema: Zoi.object(%{
  user: Zoi.object(%{
    email: Zoi.string() |> Zoi.email(),
    profile: Zoi.object(%{
      bio: Zoi.string() |> Zoi.optional(),
      website: Zoi.string() |> Zoi.optional()
    }) |> Zoi.optional()
  }),
  settings: Zoi.object(%{
    notifications: Zoi.boolean() |> Zoi.default(true)
  })
})
```

## Output Schemas

Both NimbleOptions and Zoi can validate action output:

```elixir
defmodule MyApp.Actions.ProcessData do
  use Jido.Action,
    name: "process_data",
    schema: [
      input: [type: :string, required: true]
    ],
    output_schema: [
      result: [type: :string, required: true],
      processed_at: [type: :integer, required: true]
    ]

  @impl true
  def run(params, _context) do
    {:ok, %{
      result: String.upcase(params.input),
      processed_at: System.system_time(:second)
    }}
  end
end
```

With Zoi:

```elixir
output_schema: Zoi.object(%{
  result: Zoi.string(),
  count: Zoi.integer() |> Zoi.min(0),
  status: Zoi.enum([:success, :partial, :failed])
})
```

## The Schema Adapter (`Jido.Action.Schema`)

Behind the scenes, `Jido.Action.Schema` provides a unified interface:

```elixir
# Detect schema type
Jido.Action.Schema.schema_type(my_schema)
# => :nimble | :zoi | :empty

# Validate data
{:ok, validated} = Jido.Action.Schema.validate(schema, params)

# Get known keys (for partial validation)
keys = Jido.Action.Schema.known_keys(schema)
# => [:email, :name, :age]

# Convert to JSON Schema (for AI tools)
json_schema = Jido.Action.Schema.to_json_schema(schema)

# Strict mode (recursive `additionalProperties: false` for all objects)
strict_json_schema = Jido.Action.Schema.to_json_schema(schema, strict: true)
```

## Open/Partial Validation

**Important:** Jido uses "open" validation semantics. Only fields declared in the schema are validated; extra fields pass through unchanged.

```elixir
defmodule MyApp.Actions.Step1 do
  use Jido.Action,
    name: "step1",
    schema: [
      input: [type: :string, required: true]
    ]

  def run(params, _context) do
    # params may contain extra fields from previous actions
    {:ok, Map.put(params, :step1_done, true)}
  end
end
```

This enables action composition where data flows through a chain:

```elixir
# Step1 validates :input, ignores :user_id
# Step2 validates :step1_done, ignores :input and :user_id
# All fields are preserved through the chain
{:ok, result} = Jido.Exec.Chain.chain(
  [Step1, Step2, Step3],
  %{input: "data", user_id: 123}
)
```

## AI Tool Integration

Schemas automatically power AI tool generation. The `doc` (NimbleOptions) or `description` (Zoi) fields appear in the tool schema:

```elixir
defmodule MyApp.Actions.SearchProducts do
  use Jido.Action,
    name: "search_products",
    description: "Search for products in the catalog",
    schema: [
      query: [type: :string, required: true, doc: "Search query string"],
      category: [type: {:in, ["electronics", "clothing", "home"]}, doc: "Product category"],
      max_results: [type: :integer, default: 10, doc: "Maximum results to return"]
    ]
  
  # ...
end

# Convert to AI tool format
tool = MyApp.Actions.SearchProducts.to_tool()
# => %{
#      name: "search_products",
#      description: "Search for products in the catalog",
#      function: #Function<...>,
#      parameters_schema: %{
#        "type" => "object",
#        "properties" => %{
#          "query" => %{"type" => "string", "description" => "Search query string"},
#          "category" => %{"type" => "string", "enum" => ["electronics", "clothing", "home"], ...},
#          "max_results" => %{"type" => "integer", "description" => "Maximum results to return"}
#        },
#        "required" => ["query"]
#      }
#    }

# Action.to_tool/0 emits strict schemas by default for modern LLM tool APIs
# (recursive `additionalProperties: false` on all object schemas).

# To opt out and keep legacy non-strict schema generation:
legacy_tool = Jido.Action.Tool.to_tool(MyApp.Actions.SearchProducts, strict: false)
```

See the [AI Integration Guide](ai-integration.md) for more details.

## Error Handling

Validation errors are wrapped in `Jido.Action.Error.InvalidInputError`:

```elixir
case Jido.Exec.run(MyAction, %{invalid: "params"}) do
  {:ok, result} -> 
    result
    
  {:error, %Jido.Action.Error.InvalidInputError{} = error} ->
    # error.message contains a human-readable description
    # error.details may contain field-specific info
    Logger.error("Validation failed: #{Exception.message(error)}")
end
```

For Zoi schemas, errors include path information:

```elixir
# Error for nested field
%{
  path: [:user, :email],
  message: "Invalid email format",
  code: :invalid_format
}
```

## Choosing Between NimbleOptions and Zoi

| Use NimbleOptions When | Use Zoi When |
|------------------------|--------------|
| Simple flat schemas | Complex nested structures |
| No input transformation needed | Need trim/case conversion |
| Familiar with NimbleOptions | Need custom refinements |
| Minimal dependencies | Want rich error messages |
| Config-style validation | Form/API input validation |

## Example: Complete Zoi Action

See `Jido.Tools.ZoiExample` for a production-quality example demonstrating all Zoi features:

```elixir
# Run the example
params = %{
  user: %{
    email: "  JOHN@EXAMPLE.COM  ",  # Will be trimmed and lowercased
    password: "SecurePass123!",
    name: "John Doe"
  },
  priority: :high
}

{:ok, result} = Jido.Exec.run(Jido.Tools.ZoiExample, params)
result.user.email  # => "john@example.com"
result.status      # => :approved (high priority)
```

## Best Practices

1. **Document your schemas** - Use `doc:` (NimbleOptions) or `description:` (Zoi) for AI integration
2. **Validate outputs** - Use `output_schema` to catch bugs early
3. **Transform at the boundary** - Use Zoi transformations to normalize input
4. **Keep schemas focused** - Only validate what your action needs; let extra fields pass through
5. **Use refinements for business logic** - Keep complex validation in `Zoi.refine/2`, not in `run/2`

## Related Guides

- [Actions Guide](actions-guide.md) - Core action concepts
- [AI Integration](ai-integration.md) - Using actions as AI tools
- [Error Handling](error-handling.md) - Handling validation errors
- [Testing](testing.md) - Testing validation logic
