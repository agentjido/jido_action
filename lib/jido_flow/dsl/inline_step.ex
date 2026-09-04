defmodule Jido.Flow.DSL.InlineStep do
  @moduledoc false

  alias Jido.Flow.DSL.{Expression, MacroSupport}

  @enforce_keys [:params_ast, :pattern_ast, :body_ast, :options]
  defstruct @enforce_keys

  @typedoc false
  @type t :: %__MODULE__{
          params_ast: Macro.t(),
          pattern_ast: Macro.t(),
          body_ast: Macro.t(),
          options: keyword()
        }

  @doc false
  @spec parse!(Macro.t(), term(), Macro.Env.t()) :: t()
  def parse!(bindings, options, caller) do
    bindings = if is_list(bindings), do: bindings, else: [bindings]
    parse_bindings!(bindings, options, caller)
  end

  @doc false
  @spec parse!(Macro.t(), Macro.t(), term(), Macro.Env.t()) :: t()
  def parse!(bindings, options, body_options, caller) when is_list(options) do
    parse!(bindings, merge_options!(options, body_options, caller), caller)
  end

  def parse!(left, right, options, caller) do
    parse_bindings!([left, right], options, caller)
  end

  @doc false
  @spec parse!(Macro.t(), Macro.t(), term(), term(), Macro.Env.t()) :: t()
  def parse!(left, right, options, body_options, caller) do
    parse_bindings!([left, right], merge_options!(options, body_options, caller), caller)
  end

  defp parse_bindings!(bindings, options, caller) do
    validate_options!(options, caller)

    body =
      case Keyword.fetch(options, :do) do
        {:ok, body} -> body
        :error -> MacroSupport.compile_error!(caller, "inline Step requires a do block")
      end

    parsed = Enum.map(bindings, &parse_binding!(&1, caller))
    {params, pattern} = params_and_pattern!(parsed, caller)

    %__MODULE__{
      params_ast: params,
      pattern_ast: pattern,
      body_ast: body,
      options: Keyword.delete(options, :do)
    }
  end

  defp merge_options!(options, body_options, caller) do
    validate_options!(options, caller)
    validate_options!(body_options, caller)
    options ++ body_options
  end

  defp validate_options!(options, caller) do
    MacroSupport.validate_options!(
      options,
      caller,
      "inline Step options must be a keyword list",
      "inline Step field"
    )

    Enum.each(options, fn {field, _value} ->
      unless field in [:after, :meta, :do] do
        MacroSupport.compile_error!(
          caller,
          "unsupported inline Step field: #{inspect(field)}; use only after:, meta:, and do:"
        )
      end
    end)
  end

  defp parse_binding!({:<-, _metadata, [pattern, source]}, caller) do
    kind = binding_kind!(pattern, caller)

    case Expression.parse(source) do
      {:ok, _expression} -> :ok
      {:error, error} -> error!(source, caller, "inline Step binding source: #{error.message}")
    end

    {kind, pattern, source}
  end

  defp parse_binding!(binding, caller) do
    error!(binding, caller, "expected a binding in the form name <- source")
  end

  defp binding_kind!({:_, _, context} = pattern, caller) when is_atom(context) do
    error!(pattern, caller, "a bare _ binding is not supported; use a named variable or []")
  end

  defp binding_kind!({name, _metadata, context}, _caller)
       when is_atom(name) and is_atom(context),
       do: {:named, name}

  defp binding_kind!({:%{}, _, _pairs} = pattern, caller) do
    validate_pattern!(pattern, caller)
    :map
  end

  defp binding_kind!({:%, _, _} = pattern, caller) do
    error!(pattern, caller, "top-level struct patterns are not supported in inline Step bindings")
  end

  defp binding_kind!({operator, _, _} = pattern, caller) when operator in [:^, :when] do
    validate_pattern!(pattern, caller)
  end

  defp binding_kind!(pattern, caller) do
    error!(pattern, caller, "inline Step requires a named variable or a sole map pattern")
  end

  defp params_and_pattern!([{:map, pattern, source}], _caller), do: {source, pattern}

  defp params_and_pattern!(bindings, caller) do
    if Enum.any?(bindings, &match?({:map, _, _}, &1)) do
      MacroSupport.compile_error!(caller, "a map pattern must be the only inline Step binding")
    end

    {params, patterns, _names} =
      Enum.reduce(bindings, {[], [], MapSet.new()}, fn {{:named, name}, pattern, source},
                                                       {params, patterns, names} ->
        if MapSet.member?(names, name) do
          error!(pattern, caller, "duplicate inline Step binding: #{inspect(name)}")
        end

        {[{name, source} | params], [{name, pattern} | patterns], MapSet.put(names, name)}
      end)

    {{:%{}, [line: caller.line], Enum.reverse(params)},
     {:%{}, [line: caller.line], Enum.reverse(patterns)}}
  end

  # Check only inline-header restrictions. The owner function compiler checks
  # normal Elixir pattern syntax without expanding or evaluating it here.
  defp validate_pattern!(pattern, caller) do
    Macro.prewalk(pattern, fn
      {:^, _, _} = node ->
        error!(node, caller, "pinned variables are not supported in inline Step bindings")

      {:when, _, _} = node ->
        error!(node, caller, "guards are not supported in inline Step bindings")

      {:%{}, _, pairs} = node ->
        validate_map_keys!(pairs, node, caller)
        node

      node ->
        node
    end)
  end

  defp validate_map_keys!(pairs, pattern, caller) do
    Enum.reduce(pairs, MapSet.new(), fn
      {key, _value}, seen ->
        normalized_key = Macro.postwalk(key, &normalize_literal/1)

        unless Macro.quoted_literal?(normalized_key) do
          error!(key, caller, "inline Step map pattern keys must be literals")
        end

        if MapSet.member?(seen, normalized_key) do
          error!(pattern, caller, "duplicate inline Step map key: #{Macro.to_string(key)}")
        end

        MapSet.put(seen, normalized_key)

      _update, _seen ->
        error!(pattern, caller, "map updates are not supported in inline Step patterns")
    end)
  end

  defp normalize_literal({:-, _, [number]}) when is_number(number), do: -number
  defp normalize_literal({:+, _, [number]}) when is_number(number), do: number
  defp normalize_literal({form, metadata, args}) when is_list(metadata), do: {form, [], args}
  defp normalize_literal(value), do: value

  defp error!({_form, metadata, _args}, caller, description) when is_list(metadata) do
    caller = %{caller | line: Keyword.get(metadata, :line, caller.line)}
    MacroSupport.compile_error!(caller, description)
  end

  defp error!(_expression, caller, description),
    do: MacroSupport.compile_error!(caller, description)
end
