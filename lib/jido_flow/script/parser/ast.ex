defmodule Jido.Flow.Script.Parser.AST do
  @moduledoc false

  import Jido.Flow.Script.Parser.Support, only: [script_error: 2, validate_path!: 3]

  def eval_reference!({:input, meta, [name_ast]}, vars, _parent_meta) do
    name = eval_value!(name_ast, vars, meta)

    unless is_atom(name) and not is_nil(name) do
      raise script_error(meta, "input reference expects an atom name")
    end

    {:input, name}
  end

  def eval_reference!({:result, meta, [name_ast]}, vars, _parent_meta) do
    name = eval_value!(name_ast, vars, meta)

    unless is_atom(name) and not is_nil(name) do
      raise script_error(meta, "result reference expects an atom name")
    end

    {:result, name}
  end

  def eval_reference!({:result, meta, [name_ast, path_ast]}, vars, _parent_meta) do
    name = eval_value!(name_ast, vars, meta)
    path = eval_value!(path_ast, vars, meta)

    unless is_atom(name) and not is_nil(name) do
      raise script_error(meta, "result reference expects an atom name")
    end

    validate_path!(path, meta, "result path")

    {:result, name, path}
  end

  def eval_reference!({:value, meta, [value_ast]}, vars, _parent_meta),
    do: {:value, eval_value!(value_ast, vars, meta)}

  def eval_reference!(value, vars, meta) when is_atom(value) and not is_nil(value),
    do: {:result, eval_value!(value, vars, meta)}

  def eval_reference!(other, _vars, _meta) do
    raise script_error(other, "expected input/1, result/1, result/2, or value/1")
  end

  def eval_value!(value, _vars, _meta)
      when is_atom(value) or is_binary(value) or is_integer(value) or is_float(value),
      do: value

  def eval_value!({:__aliases__, meta, parts}, _vars, _parent_meta) do
    Module.safe_concat(parts)
  rescue
    ArgumentError ->
      raise script_error(meta, "module #{Enum.join(parts, ".")} is not loaded")
  end

  def eval_value!({:%{}, meta, pairs}, vars, _parent_meta) do
    Map.new(pairs, fn
      {key, value} -> {eval_value!(key, vars, meta), eval_option_value!(value, vars, meta)}
      other -> raise script_error(other, "invalid map entry")
    end)
  end

  def eval_value!({:{}, meta, values}, vars, _parent_meta) when is_list(values) do
    values
    |> Enum.map(&eval_option_value!(&1, vars, meta))
    |> List.to_tuple()
  end

  def eval_value!({left, right}, vars, meta) do
    {eval_option_value!(left, vars, meta), eval_option_value!(right, vars, meta)}
  end

  def eval_value!({name, meta, nil}, vars, _parent_meta) when is_atom(name) do
    case Map.fetch(vars, name) do
      {:ok, value} -> value
      :error -> raise script_error(meta, "unbound script variable #{inspect(name)}")
    end
  end

  def eval_value!(values, vars, meta) when is_list(values) do
    if Keyword.keyword?(values) do
      eval_keyword!(values, vars, meta)
    else
      Enum.map(values, &eval_option_value!(&1, vars, meta))
    end
  end

  def eval_value!(other, _vars, _meta) do
    raise script_error(other, "unsupported script value")
  end

  def eval_option_value!(ast, vars, meta) do
    cond do
      reference_ast?(ast) -> eval_reference!(ast, vars, meta)
      callable_ast?(ast) -> eval_callable!(ast, vars, meta)
      true -> eval_value!(ast, vars, meta)
    end
  end

  def eval_callable!({:&, meta, [{:/, _div_meta, [call_ast, arity]}]}, _vars, _parent_meta)
      when is_integer(arity) do
    case call_ast do
      {{:., _dot_meta, [module_ast, function]}, _call_meta, []} when is_atom(function) ->
        module = eval_value!(module_ast, %{}, meta)

        unless Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
          raise script_error(
                  meta,
                  "callable #{inspect(module)}.#{function}/#{arity} is not exported"
                )
        end

        {module, function}

      _other ->
        raise script_error(meta, "unsupported external function capture")
    end
  end

  def eval_callable!(ast, vars, meta), do: eval_value!(ast, vars, meta)

  def eval_keyword!(values, vars, meta) when is_list(values) do
    if Keyword.keyword?(values) do
      Enum.map(values, fn {key, value} -> {key, eval_option_value!(value, vars, meta)} end)
    else
      raise script_error(meta, "expected keyword options")
    end
  end

  def eval_keyword!(other, _vars, _meta) do
    raise script_error(other, "expected keyword options")
  end

  def reference_ast?({name, _meta, _args}) when name in [:input, :result, :value],
    do: true

  def reference_ast?(_ast), do: false

  def callable_ast?({:&, _meta, _args}), do: true
  def callable_ast?(_ast), do: false
end
