defmodule Jido.Action.Inline.Parser do
  @moduledoc false

  alias Jido.Action.Inline

  @doc false
  @spec bound!(Macro.t(), keyword(), Macro.Env.t()) :: Inline.t()
  def bound!(bindings, options, caller) do
    bindings = if is_list(bindings), do: bindings, else: [bindings]

    if List.improper?(bindings),
      do: error!(nil, caller, "inline Action bindings must be a proper list")

    parsed =
      Enum.map(bindings, fn
        {:<-, _, [pattern, source]} -> {binding_kind!(pattern, caller), pattern, source}
        other -> error!(other, caller, "expected a binding in the form name <- source")
      end)

    {params, pattern} = params_and_pattern!(parsed, caller)
    build!(:bound, params, pattern, options, caller)
  end

  @doc false
  @spec callback!(Macro.t(), keyword(), Macro.Env.t()) :: Inline.t()
  def callback!(pattern, options, caller) do
    binding_kind!(
      pattern,
      caller,
      "inline Action callback requires a named variable or a map pattern"
    )

    build!(:callback, nil, pattern, options, caller)
  end

  defp build!(mode, params, pattern, options, caller) do
    options!(options, [:do, :name, :description, :schema, :output_schema, :context], caller)

    body =
      case Keyword.fetch(options, :do) do
        {:ok, body} -> body
        :error -> error!(nil, caller, "inline Action requires a do block")
      end

    context =
      case Keyword.fetch(options, :context) do
        :error -> nil
        {:ok, context} -> context!(context, pattern, caller)
      end

    %Inline{
      mode: mode,
      params_ast: params,
      pattern_ast: pattern,
      body_ast: body,
      options: Keyword.drop(options, [:do, :context]),
      context_ast: context
    }
  end

  @doc false
  @spec options!(term(), [atom()], Macro.Env.t(), String.t()) :: :ok
  def options!(options, supported, caller, kind \\ "option") do
    unless is_list(options) and Keyword.keyword?(options) do
      error!(options, caller, "inline Action #{kind}s must be a keyword list")
    end

    _seen =
      Enum.reduce(options, MapSet.new(), fn {key, _}, seen ->
        unless key in supported do
          error!(nil, caller, "unsupported inline Action #{kind}: #{inspect(key)}")
        end

        if MapSet.member?(seen, key) do
          error!(nil, caller, "duplicate inline Action #{kind}: #{inspect(key)}")
        end

        MapSet.put(seen, key)
      end)

    :ok
  end

  defp context!({name, _, context} = variable, pattern, caller)
       when is_atom(name) and name != :_ and is_atom(context) do
    {_pattern, names} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {name, _, context} = node, names when is_atom(name) and is_atom(context) ->
          {node, MapSet.put(names, name)}

        node, names ->
          {node, names}
      end)

    if MapSet.member?(names, name) do
      error!(
        variable,
        caller,
        "inline Action context variable collides with a parameter variable: #{name}"
      )
    end

    variable
  end

  defp context!(other, _pattern, caller),
    do: error!(other, caller, "inline Action context must be a named variable")

  defp binding_kind!(
         pattern,
         caller,
         message \\ "inline Action requires a named variable or a sole map pattern"
       )

  defp binding_kind!({:_, _, context} = pattern, caller, _message) when is_atom(context),
    do: error!(pattern, caller, "a bare _ binding is not supported; use a named variable or []")

  defp binding_kind!({name, _, context}, _caller, _message)
       when is_atom(name) and is_atom(context),
       do: {:named, name}

  defp binding_kind!({:%{}, _, _} = pattern, caller, _message) do
    validate_pattern!(pattern, caller)
    :map
  end

  defp binding_kind!({:%, _, _} = pattern, caller, _message),
    do:
      error!(
        pattern,
        caller,
        "top-level struct patterns are not supported in inline Action bindings"
      )

  defp binding_kind!({operator, _, _} = pattern, caller, _message) when operator in [:^, :when],
    do: validate_pattern!(pattern, caller)

  defp binding_kind!(pattern, caller, message), do: error!(pattern, caller, message)

  defp params_and_pattern!([{:map, pattern, source}], _caller), do: {source, pattern}

  defp params_and_pattern!(bindings, caller) do
    if Enum.any?(bindings, &match?({:map, _, _}, &1)) do
      error!(nil, caller, "a map pattern must be the only inline Action binding")
    end

    {params, patterns, _names} =
      Enum.reduce(bindings, {[], [], MapSet.new()}, fn {{:named, name}, pattern, source},
                                                       {params, patterns, names} ->
        if MapSet.member?(names, name) do
          error!(pattern, caller, "duplicate inline Action binding: #{inspect(name)}")
        end

        {[{name, source} | params], [{name, pattern} | patterns], MapSet.put(names, name)}
      end)

    {{:%{}, [line: caller.line], Enum.reverse(params)},
     {:%{}, [line: caller.line], Enum.reverse(patterns)}}
  end

  # Normal Elixir compilation checks the remaining pattern syntax in the owner.
  defp validate_pattern!(pattern, caller) do
    Macro.prewalk(pattern, fn
      {:^, _, _} = node ->
        error!(node, caller, "pinned variables are not supported in inline Action bindings")

      {:when, _, _} = node ->
        error!(node, caller, "guards are not supported in inline Action bindings")

      {:%{}, _, pairs} = node ->
        validate_map_keys!(pairs, node, caller)
        node

      node ->
        node
    end)
  end

  defp validate_map_keys!(pairs, pattern, caller) do
    Enum.reduce(pairs, MapSet.new(), fn
      {key, _}, seen ->
        normalized = Macro.postwalk(key, &normalize_literal/1)

        unless Macro.quoted_literal?(normalized),
          do: error!(key, caller, "inline Action map pattern keys must be literals")

        if MapSet.member?(seen, normalized),
          do: error!(pattern, caller, "duplicate inline Action map key: #{Macro.to_string(key)}")

        MapSet.put(seen, normalized)

      _, _ ->
        error!(pattern, caller, "map updates are not supported in inline Action patterns")
    end)
  end

  defp normalize_literal({:-, _, [number]}) when is_number(number), do: -number
  defp normalize_literal({:+, _, [number]}) when is_number(number), do: number
  defp normalize_literal({form, metadata, args}) when is_list(metadata), do: {form, [], args}
  defp normalize_literal(value), do: value

  @doc false
  @spec error!(term(), Macro.Env.t(), String.t()) :: no_return()
  def error!({_form, metadata, _args}, caller, description) when is_list(metadata),
    do: error!(nil, %{caller | line: Keyword.get(metadata, :line, caller.line)}, description)

  def error!(_value, caller, description),
    do: raise(CompileError, file: caller.file, line: caller.line, description: description)
end
