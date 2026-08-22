defmodule Jido.Flow.Syntax do
  @moduledoc false

  import Kernel, except: [in: 2, not: 1]

  defmodule Expr do
    @moduledoc false

    @schema Zoi.struct(
              __MODULE__,
              %{
                type:
                  Zoi.enum(
                    [
                      :input,
                      :context,
                      :value,
                      :result,
                      :binding,
                      :select,
                      :item,
                      :item_index,
                      :item_id,
                      :accumulator,
                      :state,
                      :iteration_index,
                      :body_result
                    ],
                    description: "Expression type"
                  ),
                node: Zoi.string(description: "Result node name") |> Zoi.optional(),
                binding: Zoi.atom(description: "Source binding alias") |> Zoi.optional(),
                source: Zoi.any(description: "Projection source expression") |> Zoi.optional(),
                path: Zoi.list(Zoi.any(), description: "Nested value path") |> Zoi.default([]),
                value: Zoi.any(description: "Literal value") |> Zoi.optional()
              },
              coerce: true
            )

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)
  end

  defmodule Condition do
    @moduledoc false

    @type t :: %__MODULE__{operator: atom(), operands: [term()]}

    @enforce_keys [:operator, :operands]
    defstruct [:operator, :operands]
  end

  defmodule Option do
    @moduledoc false

    @type t :: %__MODULE__{
            name: atom() | String.t(),
            condition: Jido.Flow.Syntax.Condition.t(),
            action: module(),
            input: term()
          }

    @enforce_keys [:name, :condition, :action, :input]
    defstruct [:name, :condition, :action, :input]
  end

  defmodule Fallback do
    @moduledoc false

    @type t :: %__MODULE__{action: module(), input: term()}

    @enforce_keys [:action, :input]
    defstruct [:action, :input]
  end

  defmodule Operation do
    @moduledoc false

    @schema Zoi.struct(
              __MODULE__,
              %{
                kind: Zoi.atom(description: "Syntax operation kind"),
                attrs: Zoi.map(description: "Operation attributes") |> Zoi.default(%{}),
                provenance: Zoi.map(description: "Non-semantic provenance") |> Zoi.default(%{})
              },
              coerce: true
            )

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)
  end

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Flow name"),
              description: Zoi.string(description: "Flow description") |> Zoi.optional(),
              schema: Zoi.any(description: "Flow input schema") |> Zoi.default([]),
              output_schema: Zoi.any(description: "Flow output schema") |> Zoi.default([]),
              operations:
                Zoi.list(Zoi.any(), description: "Flow syntax operations") |> Zoi.default([]),
              provenance: Zoi.map(description: "Non-semantic provenance") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Builds an empty syntax artifact.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()
  def new(%{} = attrs), do: struct!(__MODULE__, attrs)

  @doc """
  Appends a syntax operation.
  """
  @spec add(t(), Operation.t()) :: t()
  def add(%__MODULE__{} = syntax, %Operation{} = operation) do
    %{syntax | operations: syntax.operations ++ [operation]}
  end

  @doc """
  Builds a generic syntax operation.
  """
  @spec operation(atom(), map() | keyword(), keyword()) :: Operation.t()
  def operation(kind, attrs \\ [], opts \\ []) when is_atom(kind) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs
    %Operation{kind: kind, attrs: attrs, provenance: Keyword.get(opts, :provenance, %{})}
  end

  @doc """
  Builds an input expression.
  """
  @spec input(term()) :: Expr.t()
  def input(path), do: %Expr{type: :input, path: normalize_path(path)}

  @doc """
  Builds a runtime context expression.
  """
  @spec context(term()) :: Expr.t()
  def context(path), do: %Expr{type: :context, path: normalize_path(path)}

  @doc """
  Builds a literal value expression.
  """
  @spec value(term()) :: Expr.t()
  def value(value), do: %Expr{type: :value, value: value}

  @doc """
  Builds a result reference expression.
  """
  @spec result(atom() | String.t(), term()) :: Expr.t()
  def result(node, path \\ []) do
    %Expr{type: :result, node: normalize_node_name(node), path: normalize_path(path)}
  end

  @doc """
  Builds a source-level binding expression.
  """
  @spec binding(atom()) :: Expr.t()
  def binding(name), do: %Expr{type: :binding, binding: name}

  @doc """
  Builds a projection expression over an existing Flow source.
  """
  @spec select(term(), term()) :: Expr.t()
  def select(source, path), do: %Expr{type: :select, source: source, path: normalize_path(path)}

  @doc "Builds a scoped reference to the current Map or Reduce item."
  @spec item(term()) :: Expr.t()
  def item(path \\ nil), do: %Expr{type: :item, path: normalize_path(path)}

  @doc "Builds a scoped reference to the current item index."
  @spec item_index() :: Expr.t()
  def item_index, do: %Expr{type: :item_index}

  @doc "Builds a scoped reference to the current stable item identity."
  @spec item_id() :: Expr.t()
  def item_id, do: %Expr{type: :item_id}

  @doc "Builds a scoped reference to the current Reduce accumulator."
  @spec accumulator(term()) :: Expr.t()
  def accumulator(path \\ nil),
    do: %Expr{type: :accumulator, path: normalize_path(path)}

  @doc "Builds a scoped reference to the current Iterator State."
  @spec state(term()) :: Expr.t()
  def state(path \\ nil), do: %Expr{type: :state, path: normalize_path(path)}

  @doc "Builds a scoped reference to the current Iterator iteration index."
  @spec iteration_index() :: Expr.t()
  def iteration_index, do: %Expr{type: :iteration_index}

  @doc "Builds a scoped reference to the latest Iterator body result."
  @spec body_result(term()) :: Expr.t()
  def body_result(path \\ nil),
    do: %Expr{type: :body_result, path: normalize_path(path)}

  @doc """
  Builds an equality condition for a Choice option.
  """
  @spec eq(term(), term()) :: Condition.t()
  def eq(left, right), do: condition(:eq, [left, right])

  @doc "Builds an inequality condition for a Choice option."
  @spec neq(term(), term()) :: Condition.t()
  def neq(left, right), do: condition(:neq, [left, right])

  @doc "Builds a less-than condition for a Choice option."
  @spec lt(term(), term()) :: Condition.t()
  def lt(left, right), do: condition(:lt, [left, right])

  @doc "Builds a less-than-or-equal condition for a Choice option."
  @spec lte(term(), term()) :: Condition.t()
  def lte(left, right), do: condition(:lte, [left, right])

  @doc "Builds a greater-than condition for a Choice option."
  @spec gt(term(), term()) :: Condition.t()
  def gt(left, right), do: condition(:gt, [left, right])

  @doc "Builds a greater-than-or-equal condition for a Choice option."
  @spec gte(term(), term()) :: Condition.t()
  def gte(left, right), do: condition(:gte, [left, right])

  @doc "Builds a list-membership condition for a Choice option."
  @spec unquote(:in)(term(), term()) :: Condition.t()
  def unquote(:in)(left, right), do: condition(:in, [left, right])

  @doc "Builds a Choice condition that requires all child conditions to be true."
  @spec all([Condition.t()]) :: Condition.t()
  def all(conditions), do: condition(:all, conditions)

  @doc "Builds a Choice condition that requires one child condition to be true."
  @spec any([Condition.t()]) :: Condition.t()
  def any(conditions), do: condition(:any, conditions)

  @doc "Builds a Choice condition that inverts one child condition."
  @spec not Condition.t() :: Condition.t()
  def not condition, do: condition(:not, [condition])

  @doc """
  Builds one named Choice option.
  """
  @spec option(atom() | String.t(), Condition.t(), module(), term()) :: Option.t()
  def option(name, condition, action, input \\ %{}) do
    %Option{name: name, condition: condition, action: action, input: input}
  end

  @doc """
  Builds the required Choice fallback.
  """
  @spec fallback(module(), term()) :: Fallback.t()
  def fallback(action, input \\ %{}), do: %Fallback{action: action, input: input}

  @doc """
  Builds a named branch operation for static branch grouping.
  """
  @spec branch(atom(), [Operation.t()], keyword()) :: Operation.t()
  def branch(name, operations, opts \\ []) do
    operation(
      :branch,
      %{name: name, operations: operations},
      provenance: Keyword.get(opts, :provenance, %{})
    )
  end

  @doc """
  Appends a provenance-only group operation.
  """
  @spec group(t(), [Operation.t()], keyword()) :: t()
  def group(%__MODULE__{} = syntax, branches, opts \\ []) do
    add(
      syntax,
      operation(:group, %{branches: branches}, provenance: Keyword.get(opts, :provenance, %{}))
    )
  end

  @doc """
  Appends a step operation.
  """
  @spec step(t(), atom() | String.t() | nil, module(), term(), keyword()) :: t()
  def step(%__MODULE__{} = syntax, name, action, input, opts \\ []) do
    attrs =
      %{
        name: name,
        action: action,
        input: input
      }
      |> maybe_put_binding(Keyword.get(opts, :bind))
      |> maybe_put_after(Keyword.get(opts, :after))

    add(
      syntax,
      operation(:step, attrs, provenance: provenance_from_options(opts))
    )
  end

  @doc """
  Appends a Map fan-out operation.
  """
  @spec map(t(), atom() | String.t() | nil, term(), module(), term(), keyword()) :: t()
  def map(%__MODULE__{} = syntax, name, collection, action, input, opts \\ []) do
    option_errors =
      operation_option_errors(opts, [
        :on_error,
        :bind,
        :after,
        :provenance,
        :label,
        :tags,
        :note
      ])

    attrs =
      %{
        name: name,
        collection: collection,
        action: action,
        input: input,
        on_error: option_value(opts, :on_error, :fail_fast)
      }
      |> maybe_put_binding(option_value(opts, :bind))
      |> maybe_put_after(option_value(opts, :after))
      |> maybe_put_option_errors(option_errors)

    add(syntax, operation(:map, attrs, provenance: provenance_from_options(opts)))
  end

  @doc """
  Appends a serial Reduce fan-in operation.
  """
  @spec reduce(
          t(),
          atom() | String.t() | nil,
          term(),
          term(),
          module(),
          term(),
          keyword()
        ) :: t()
  def reduce(%__MODULE__{} = syntax, name, collection, initial, action, input, opts \\ []) do
    option_errors =
      operation_option_errors(opts, [:bind, :after, :provenance, :label, :tags, :note])

    attrs =
      %{
        name: name,
        collection: collection,
        initial: initial,
        action: action,
        input: input
      }
      |> maybe_put_binding(option_value(opts, :bind))
      |> maybe_put_after(option_value(opts, :after))
      |> maybe_put_option_errors(option_errors)

    add(syntax, operation(:reduce, attrs, provenance: provenance_from_options(opts)))
  end

  @doc "Appends one bounded, stateful Iterate operation."
  @spec iterate(t(), atom() | String.t() | nil, module(), term(), map() | keyword(), keyword()) ::
          t()
  def iterate(%__MODULE__{} = syntax, name, action, input, state, opts \\ []) do
    option_errors =
      operation_option_errors(opts, [
        :while,
        :until,
        :repeat,
        :max_iterations,
        :bind,
        :after,
        :provenance,
        :label,
        :tags,
        :note
      ])

    attrs =
      %{
        name: name,
        action: action,
        input: input,
        state: state
      }
      |> maybe_put_present_option(opts, :while)
      |> maybe_put_present_option(opts, :until)
      |> maybe_put_present_option(opts, :repeat)
      |> maybe_put_present_option(opts, :max_iterations)
      |> maybe_put_binding(option_value(opts, :bind))
      |> maybe_put_after(option_value(opts, :after))
      |> maybe_put_option_errors(option_errors)

    add(syntax, operation(:iterate, attrs, provenance: provenance_from_options(opts)))
  end

  @doc """
  Appends a named ordered Choice operation.
  """
  @spec choice(t(), atom() | String.t() | nil, [Option.t()], Fallback.t(), keyword()) :: t()
  def choice(%__MODULE__{} = syntax, name, options, fallback, opts \\ []) do
    attrs =
      %{
        name: name,
        options: options,
        fallback: fallback
      }
      |> maybe_put_binding(Keyword.get(opts, :bind))
      |> maybe_put_after(Keyword.get(opts, :after))

    add(syntax, operation(:choice, attrs, provenance: provenance_from_options(opts)))
  end

  @doc """
  Appends the return declaration.
  """
  @spec return(t(), term()) :: t()
  def return(%__MODULE__{} = syntax, expr) do
    add(syntax, operation(:return, %{expr: expr}))
  end

  defp normalize_path(nil), do: []
  defp normalize_path(path) when is_list(path), do: path
  defp normalize_path(path), do: [path]

  defp normalize_node_name(node) when is_atom(node) and node != nil, do: Atom.to_string(node)
  defp normalize_node_name(node) when is_binary(node), do: node

  defp condition(operator, operands), do: %Condition{operator: operator, operands: operands}

  defp maybe_put_binding(attrs, nil), do: attrs
  defp maybe_put_binding(attrs, binding), do: Map.put(attrs, :binding, binding)

  defp maybe_put_after(attrs, nil), do: attrs
  defp maybe_put_after(attrs, after_targets), do: Map.put(attrs, :after, after_targets)

  defp maybe_put_option_errors(attrs, []), do: attrs
  defp maybe_put_option_errors(attrs, errors), do: Map.put(attrs, :option_errors, errors)

  defp maybe_put_present_option(attrs, opts, option) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.has_key?(opts, option) do
      Map.put(attrs, option, Keyword.get(opts, option))
    else
      attrs
    end
  end

  defp maybe_put_present_option(attrs, _opts, _option), do: attrs

  defp operation_option_errors(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keyword_option_errors(opts, allowed)
    else
      [{:invalid, opts}]
    end
  end

  defp operation_option_errors(opts, _allowed), do: [{:invalid, opts}]

  defp keyword_option_errors(opts, allowed) do
    keys = Keyword.keys(opts)
    unique_keys = Enum.uniq(keys)
    frequencies = Enum.frequencies(keys)

    unsupported =
      Enum.find(unique_keys, fn candidate ->
        Enum.member?(allowed, candidate) == false
      end)

    duplicate = Enum.find(unique_keys, &(Map.fetch!(frequencies, &1) > 1))
    option_errors(unsupported, duplicate)
  end

  defp option_errors(nil, nil), do: []
  defp option_errors(nil, duplicate), do: [{:duplicate, duplicate}]
  defp option_errors(unsupported, _duplicate), do: [{:unsupported, unsupported}]

  defp option_value(opts, name, default \\ nil)

  defp option_value(opts, name, default) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, name, default), else: default
  end

  defp option_value(_opts, _name, default), do: default

  defp provenance_from_options(opts) do
    provenance = option_value(opts, :provenance, %{})

    if is_map(provenance) do
      Map.merge(provenance, annotation_options(opts))
    else
      provenance
    end
  end

  defp annotation_options(opts) do
    if(is_list(opts) and Keyword.keyword?(opts), do: opts, else: [])
    |> Keyword.take([:label, :tags, :note])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
