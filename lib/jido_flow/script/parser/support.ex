defmodule Jido.Flow.Script.Parser.Support do
  @moduledoc false

  alias Jido.Flow.Ref

  def reject_unknown_opts!(opts, allowed, meta, form) do
    reject_duplicate_opts!(opts, meta, form)

    unknown =
      opts
      |> Keyword.keys()
      |> Enum.reject(&(&1 in allowed))

    case unknown do
      [] ->
        opts

      [option | _rest] ->
        raise script_error(meta, "unsupported #{form} option #{inspect(option)}")
    end
  end

  def reject_duplicate_opts!(opts, meta, form) do
    duplicate =
      opts
      |> Keyword.keys()
      |> Enum.frequencies()
      |> Enum.find_value(fn
        {key, count} when count > 1 -> key
        _entry -> nil
      end)

    if duplicate do
      raise script_error(meta, "#{form} option #{inspect(duplicate)} can only be declared once")
    end

    opts
  end

  def reject_block_contents!(block, form, meta) do
    case expressions(block) do
      [] -> :ok
      _expressions -> raise script_error(meta, "#{form} does not support a do block")
    end
  end

  def require_entries!([], meta, form), do: raise(script_error(meta, "#{form} cannot be empty"))
  def require_entries!(_entries, _meta, _form), do: :ok

  def reject_nested_state!(%{inputs: [_input | _rest]}, meta, form) do
    raise script_error(meta, "#{form} cannot declare input/1")
  end

  def reject_nested_state!(%{return: return}, meta, form) when not is_nil(return) do
    raise script_error(meta, "#{form} cannot declare return/1")
  end

  def reject_nested_state!(_state, _meta, _form), do: :ok

  def reject_nested_inputs!(%{inputs: [_input | _rest]}, meta, form) do
    raise script_error(meta, "#{form} cannot declare input/1")
  end

  def reject_nested_inputs!(_state, _meta, _form), do: :ok

  def require_reduce_block!(fields, meta, form) do
    unless Map.has_key?(fields, :init) and Map.has_key?(fields, :reducer) do
      raise script_error(meta, "#{form} block expects init/1 and run/1")
    end
  end

  def require_arguments!(arguments, meta) when map_size(arguments) == 0 do
    raise script_error(meta, "collect expects at least one argument")
  end

  def require_arguments!(_arguments, _meta), do: :ok

  def put_argument!(arguments, name, value, meta) do
    if Map.has_key?(arguments, name) do
      raise script_error(meta, "argument #{inspect(name)} can only be declared once")
    end

    Map.put(arguments, name, value)
  end

  def put_block_field!(fields, key, value, meta, label) do
    if Map.has_key?(fields, key) do
      raise script_error(meta, "#{label} can only be declared once")
    end

    Map.put(fields, key, value)
  end

  def require_atom_name!(value, _meta, _label) when is_atom(value) and not is_nil(value),
    do: value

  def require_atom_name!(_value, meta, label),
    do: raise(script_error(meta, "#{label} expects an atom"))

  def normalize_optional_atom_name!(nil, _meta, _label), do: nil

  def normalize_optional_atom_name!(value, meta, label),
    do: require_atom_name!(value, meta, label)

  def validate_path!(path, meta, label) do
    case Ref.validate_path(path) do
      :ok -> path
      {:error, _reason} -> raise_path_error(path, meta, label)
    end
  end

  def raise_path_error(_path, meta, label) do
    raise script_error(
            meta,
            "#{label} expects a non-empty list of atoms or non-negative integers"
          )
  end

  def raise_source_error(meta) do
    raise script_error(meta, "source expects input/1, result/1, result/2, or value/1")
  end

  def raise_over_error(meta) do
    raise script_error(meta, "over expects an atom or {:name, from: :source, path: [...]}")
  end

  def raise_unknown_over_option(meta) do
    raise script_error(meta, "over supports only :from and :path")
  end

  def reject_source_conflict!(source, over, block_source, meta, form) do
    declared =
      [source, over, block_source]
      |> Enum.reject(&is_nil/1)
      |> length()

    if declared > 1 do
      raise script_error(meta, "#{form} accepts only one source declaration")
    end
  end

  def normalize_source_ref!(source, meta) do
    case Ref.normalize_source(source) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> raise_source_error(meta)
    end
  end

  def validate_debug_fields!(label, limit, meta) do
    if not is_nil(label) and not is_binary(label) do
      raise script_error(meta, "debug label expects a string")
    end

    if not is_nil(limit) and not (is_integer(limit) and limit > 0) do
      raise script_error(meta, "debug limit expects a positive integer")
    end
  end

  def validate_switch!(%{on: nil}, meta), do: raise(script_error(meta, "switch expects on/1"))

  def validate_switch!(%{matches: []}, meta),
    do: raise(script_error(meta, "switch expects at least one matches? entry"))

  def validate_switch!(%{return?: return?}, meta) when not is_boolean(return?) do
    raise script_error(meta, "switch return expects a boolean")
  end

  def validate_switch!(switch, _meta), do: switch

  def normalize_params!(value, _meta) when is_map(value), do: value

  def normalize_params!(value, meta) when is_list(value) do
    if Keyword.keyword?(value),
      do: Map.new(value),
      else: raise(script_error(meta, "params must be a map"))
  end

  def normalize_params!(_value, meta), do: raise(script_error(meta, "params must be a map"))

  def normalize_context!(value, _meta) when is_map(value), do: value

  def normalize_context!(value, meta) when is_list(value) do
    if Keyword.keyword?(value),
      do: Map.new(value),
      else: raise(script_error(meta, "context must be a map"))
  end

  def normalize_context!(_value, meta), do: raise(script_error(meta, "context must be a map"))

  def normalize_wait_for!(nil, _meta), do: nil

  def normalize_wait_for!(values, meta) when is_list(values) do
    cond do
      values == [] -> raise script_error(meta, "wait_for cannot be empty")
      Enum.all?(values, &is_atom/1) -> values
      true -> raise script_error(meta, "wait_for expects atom names")
    end
  end

  def normalize_wait_for!(value, _meta) when is_atom(value), do: value

  def normalize_wait_for!(_value, meta),
    do: raise(script_error(meta, "wait_for expects atom names"))

  def normalize_over!(over, meta) do
    case Ref.normalize_over(over) do
      {:ok, normalized} ->
        normalized

      {:error, "over supports only :from and :path"} ->
        raise_unknown_over_option(meta)

      {:error, "from must be an atom"} ->
        raise script_error(meta, "over from expects an atom")

      {:error, "path must be a non-empty list"} ->
        raise_path_error(over, meta, "over path")

      {:error, "path must contain only atoms or non-negative integers"} ->
        raise_path_error(over, meta, "over path")

      {:error, "over option " <> _rest = reason} ->
        raise script_error(meta, reason)

      {:error, _reason} ->
        raise_over_error(meta)
    end
  end

  def dependency_from_over(over), do: Ref.over_dependency(over)
  def dependency_from_source(source), do: Ref.dependency(source)
  def dependencies_from_arguments(arguments), do: Ref.dependency_list(arguments)
  def map_from_source(source), do: Ref.map_from_source(source)

  def split_call!(args, meta, name, positional_count) do
    unless is_list(args) do
      raise script_error(meta, "#{name} expects #{positional_count} positional arguments")
    end

    {args, block} = pop_do_block(args)
    {positionals, opts} = pop_options(args)

    unless length(positionals) == positional_count do
      raise script_error(meta, "#{name} expects #{positional_count} positional arguments")
    end

    {positionals, opts, block}
  end

  def split_call_any!(args, meta, name, positional_counts) do
    unless is_list(args) do
      raise script_error(
              meta,
              "#{name} expects #{Enum.map_join(positional_counts, " or ", &to_string/1)} positional arguments"
            )
    end

    {args, block} = pop_do_block(args)
    {positionals, opts} = pop_options(args)

    unless length(positionals) in positional_counts do
      raise script_error(
              meta,
              "#{name} expects #{Enum.map_join(positional_counts, " or ", &to_string/1)} positional arguments"
            )
    end

    {positionals, opts, block}
  end

  def pop_do_block(args) do
    case List.last(args) do
      opts when is_list(opts) ->
        if Keyword.keyword?(opts) do
          {block, opts} = Keyword.pop(opts, :do)
          args = if opts == [], do: Enum.drop(args, -1), else: List.replace_at(args, -1, opts)
          {args, block}
        else
          {args, nil}
        end

      _other ->
        {args, nil}
    end
  end

  def pop_options(args) do
    case List.last(args) do
      opts when is_list(opts) ->
        if Keyword.keyword?(opts), do: {Enum.drop(args, -1), opts}, else: {args, []}

      _other ->
        {args, []}
    end
  end

  def expressions({:__block__, _meta, expressions}), do: expressions
  def expressions(nil), do: []
  def expressions(expression), do: [expression]

  def script_error(meta, message) when is_list(meta) do
    location =
      case {Keyword.get(meta, :line), Keyword.get(meta, :column)} do
        {nil, _column} -> ""
        {line, nil} -> " at line #{line}"
        {line, column} -> " at line #{line}, column #{column}"
      end

    ArgumentError.exception("invalid flow script#{location}: #{message}")
  end

  def script_error({form, meta, _args}, message) when is_atom(form) and is_list(meta),
    do: script_error(meta, message)

  def script_error(_other, message),
    do: ArgumentError.exception("invalid flow script: #{message}")
end
