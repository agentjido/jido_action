defmodule Jido.Flow.Script do
  @moduledoc """
  Experimental parser for a restricted Elixir-shaped flow script.

  This module uses `Code.string_to_quoted/2` only as a parser. It does not
  evaluate, compile, macro-expand, or invoke arbitrary code from the script.
  Static atoms are encoded into data while parsing so untrusted input cannot
  grow the atom table.

  Supported shape:

      flow "checkout" do
        step "load_cart", "MyApp.Actions.LoadCart"

        step "price_cart", MyApp.Actions.PriceCart,
          after: "load_cart",
          params: %{currency: "USD"}
      end
  """

  alias Jido.Action.{Error, Util}
  alias Jido.Flow
  alias Jido.Flow.Step

  @atom_tag :__jido_flow_script_atom__
  @default_max_bytes 32_000
  @default_max_steps 100
  @default_max_string_bytes 2_048

  @step_option_keys ~w(after params context)

  @doc """
  Parses a restricted flow script into a `Jido.Flow`.
  """
  @spec compile(String.t(), keyword()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def compile(source, opts \\ []) when is_binary(source) and is_list(opts) do
    with :ok <- validate_source_size(source, opts),
         {:ok, quoted} <- parse(source),
         {:ok, flow_spec} <- decode_flow(quoted, opts) do
      build_flow(flow_spec)
    end
  end

  @doc """
  Parses a restricted flow script or raises on failure.
  """
  @spec compile!(String.t(), keyword()) :: Flow.t() | no_return()
  def compile!(source, opts \\ []) do
    case compile(source, opts) do
      {:ok, flow} -> flow
      {:error, error} when is_exception(error) -> raise error
      {:error, reason} -> raise Error.validation_error("Invalid flow script", %{reason: reason})
    end
  end

  @doc false
  @spec encode_static_atom(binary(), keyword()) :: {:ok, tuple()}
  def encode_static_atom(value, _metadata), do: {:ok, {@atom_tag, value}}

  defp validate_source_size(source, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    cond do
      not is_integer(max_bytes) or max_bytes <= 0 ->
        validation_error(":max_bytes must be a positive integer", %{max_bytes: max_bytes})

      byte_size(source) > max_bytes ->
        validation_error("flow script is too large", %{
          max_bytes: max_bytes,
          byte_size: byte_size(source)
        })

      true ->
        :ok
    end
  end

  defp parse(source) do
    Code.string_to_quoted(source,
      columns: true,
      existing_atoms_only: true,
      static_atoms_encoder: &__MODULE__.encode_static_atom/2,
      emit_warnings: false
    )
    |> case do
      {:ok, quoted} ->
        {:ok, erase_parser_type(quoted)}

      {:error, {metadata, prefix, suffix}} ->
        validation_error("invalid flow script syntax", %{
          line: Keyword.get(metadata, :line),
          column: Keyword.get(metadata, :column),
          reason: parse_reason(prefix, suffix)
        })
    end
  end

  @spec erase_parser_type(term()) :: term()
  defp erase_parser_type(term), do: term |> :erlang.term_to_binary() |> :erlang.binary_to_term()

  defp parse_reason(prefix, suffix) do
    prefix =
      case prefix do
        {left, right} -> left <> right
        value when is_binary(value) -> value
      end

    prefix <> suffix
  end

  defp decode_flow({{@atom_tag, "flow"}, _metadata, [name_ast, [do: block_ast]]}, opts) do
    with {:ok, name} <- decode_name(name_ast, :flow),
         {:ok, steps} <- decode_steps(block_ast, opts) do
      {:ok, %{name: name, steps: steps}}
    end
  end

  defp decode_flow(_quoted, _opts) do
    validation_error("expected a single flow block", %{
      expected: ~s(flow "name" do ... end)
    })
  end

  defp decode_steps({:__block__, _metadata, step_asts}, opts) do
    decode_step_list(step_asts, opts)
  end

  defp decode_steps(step_ast, opts), do: decode_step_list([step_ast], opts)

  defp decode_step_list(step_asts, opts) when is_list(step_asts) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)

    cond do
      not is_integer(max_steps) or max_steps <= 0 ->
        validation_error(":max_steps must be a positive integer", %{max_steps: max_steps})

      length(step_asts) > max_steps ->
        validation_error("flow script contains too many steps", %{
          max_steps: max_steps,
          step_count: length(step_asts)
        })

      true ->
        step_asts
        |> Enum.reduce_while({:ok, []}, fn step_ast, {:ok, steps} ->
          case decode_step(step_ast) do
            {:ok, step} -> {:cont, {:ok, [step | steps]}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
        |> case do
          {:ok, steps} -> {:ok, Enum.reverse(steps)}
          error -> error
        end
    end
  end

  defp decode_step({{@atom_tag, "step"}, _metadata, [name_ast, action_ast]}) do
    decode_step(name_ast, action_ast, [])
  end

  defp decode_step({{@atom_tag, "step"}, _metadata, [name_ast, action_ast, options_ast]}) do
    with {:ok, options} <- decode_step_options(options_ast) do
      decode_step(name_ast, action_ast, options)
    end
  end

  defp decode_step({{@atom_tag, "step"}, _metadata, args}) do
    validation_error("step expects a name, action, and optional keyword options", %{
      arity: length(args)
    })
  end

  defp decode_step(_quoted) do
    validation_error("flow blocks may only contain step calls", %{
      expected: ~s(step "name", "MyApp.Action")
    })
  end

  defp decode_step(name_ast, action_ast, options) do
    with {:ok, name} <- decode_name(name_ast, :step),
         {:ok, action} <- decode_action(action_ast),
         :ok <- validate_action(action) do
      {:ok, %{name: name, action: action, options: options}}
    end
  end

  defp decode_step_options(options_ast) when is_list(options_ast) do
    options_ast
    |> Enum.reduce_while({:ok, []}, fn
      {{@atom_tag, key}, value_ast}, {:ok, options} ->
        if key in @step_option_keys do
          decode_step_option(key, value_ast, options)
        else
          {:halt,
           validation_error("unsupported step option", %{
             option: key,
             allowed: @step_option_keys
           })}
        end

      _other, _acc ->
        {:halt, validation_error("step options must be a keyword list", %{})}
    end)
    |> case do
      {:ok, options} -> {:ok, Enum.reverse(options)}
      error -> error
    end
  end

  defp decode_step_options(_options_ast) do
    validation_error("step options must be a keyword list", %{})
  end

  defp decode_step_option("after", value_ast, options) do
    case decode_dependency(value_ast) do
      {:ok, dependency} -> put_unique_option(options, :after, dependency)
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp decode_step_option("params", value_ast, options) do
    case decode_map_literal(value_ast, :params) do
      {:ok, params} -> put_unique_option(options, :params, params)
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp decode_step_option("context", value_ast, options) do
    case decode_map_literal(value_ast, :context) do
      {:ok, context} -> put_unique_option(options, :context, context)
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp put_unique_option(options, key, value) when is_list(options) do
    if Keyword.has_key?(options, key) do
      {:halt, validation_error("duplicate step option", %{option: key})}
    else
      {:cont, {:ok, Keyword.put(options, key, value)}}
    end
  end

  defp decode_dependency(value_ast) when is_list(value_ast) do
    value_ast
    |> Enum.reduce_while({:ok, []}, fn dependency_ast, {:ok, dependencies} ->
      case decode_name(dependency_ast, :after) do
        {:ok, dependency} -> {:cont, {:ok, [dependency | dependencies]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, dependencies} -> {:ok, Enum.reverse(dependencies)}
      error -> error
    end
  end

  defp decode_dependency(value_ast), do: decode_name(value_ast, :after)

  defp decode_name({@atom_tag, value}, field), do: validate_script_name(value, field)
  defp decode_name(value, field) when is_binary(value), do: validate_script_name(value, field)

  defp decode_name(_value, field) do
    validation_error("#{field} name must be a string or atom literal", %{field: field})
  end

  defp validate_script_name(value, field) do
    max_string_bytes = @default_max_string_bytes

    with :ok <- validate_script_component_name(value, field) do
      if byte_size(value) > max_string_bytes do
        validation_error("#{field} name is too large", %{
          field: field,
          max_bytes: max_string_bytes,
          byte_size: byte_size(value)
        })
      else
        {:ok, value}
      end
    end
  end

  defp validate_script_component_name(value, field) do
    case Util.validate_component_name(value) do
      :ok ->
        :ok

      {:error, "cannot be empty"} ->
        validation_error("#{field} name cannot be empty", %{field: field})

      {:error, reason} ->
        validation_error("#{field} name #{reason}", %{field: field})
    end
  end

  defp decode_action(value) when is_binary(value) do
    with {:ok, module_string} <- normalize_module_string(value) do
      existing_action_module(module_string)
    end
  end

  defp decode_action({:__aliases__, _metadata, parts}) when is_list(parts) do
    with {:ok, module_string} <- decode_alias_parts(parts) do
      existing_action_module(module_string)
    end
  end

  defp decode_action(_value) do
    validation_error("action must be a module alias or module name string", %{})
  end

  defp decode_alias_parts(parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn
      {@atom_tag, part}, {:ok, acc} ->
        if module_part?(part) do
          {:cont, {:ok, [part | acc]}}
        else
          {:halt, validation_error("invalid module alias segment", %{segment: part})}
        end

      _part, _acc ->
        {:halt, validation_error("invalid module alias segment", %{})}
    end)
    |> case do
      {:ok, parts} ->
        parts
        |> Enum.reverse()
        |> Enum.join(".")
        |> normalize_module_string()

      error ->
        error
    end
  end

  defp normalize_module_string("Elixir." <> module), do: normalize_module_string(module)

  defp normalize_module_string(module) when is_binary(module) do
    if module_string?(module) do
      {:ok, "Elixir." <> module}
    else
      validation_error("invalid module name", %{module: module})
    end
  end

  defp existing_action_module(module_string) when is_binary(module_string) do
    module = String.to_existing_atom(module_string)

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      validation_error("action module is not loaded", %{module: module_string})
    end
  rescue
    ArgumentError ->
      validation_error("action module must already exist", %{module: module_string})
  end

  defp validate_action(action) do
    case Step.validate_action(action) do
      :ok -> :ok
      {:error, error} -> validation_error(Exception.message(error), %{action: inspect(action)})
    end
  end

  defp module_string?(module) do
    module
    |> String.split(".")
    |> Enum.all?(&module_part?/1)
  end

  defp module_part?(part), do: Regex.match?(~r/^[A-Z][A-Za-z0-9_]*$/, part)

  defp decode_map_literal({:%{}, _metadata, pairs}, field) do
    pairs
    |> Enum.reduce_while({:ok, []}, fn
      {key_ast, value_ast}, {:ok, pairs} ->
        with {:ok, key} <- decode_map_key(key_ast),
             {:ok, value} <- decode_literal(value_ast) do
          {:cont, {:ok, [{key, value} | pairs]}}
        else
          {:error, error} -> {:halt, {:error, error}}
        end

      _other, _acc ->
        {:halt, validation_error("#{field} must be a map literal", %{field: field})}
    end)
    |> case do
      {:ok, pairs} -> {:ok, pairs |> Enum.reverse() |> Map.new()}
      error -> error
    end
  end

  defp decode_map_literal(_value, field) do
    validation_error("#{field} must be a map literal", %{field: field})
  end

  defp decode_map_key({@atom_tag, value}), do: existing_atom(value, :map_key)
  defp decode_map_key(value) when is_binary(value), do: {:ok, value}
  defp decode_map_key(value) when is_integer(value), do: {:ok, value}

  defp decode_map_key(_value) do
    validation_error("map keys must be strings, integers, or existing atom literals", %{})
  end

  defp decode_literal(value)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: {:ok, value}

  defp decode_literal(value) when is_binary(value) do
    if byte_size(value) > @default_max_string_bytes do
      validation_error("string literal is too large", %{
        max_bytes: @default_max_string_bytes,
        byte_size: byte_size(value)
      })
    else
      {:ok, value}
    end
  end

  defp decode_literal({@atom_tag, value}), do: existing_atom(value, :literal)

  defp decode_literal({:%{}, _metadata, _pairs} = value), do: decode_map_literal(value, :literal)

  defp decode_literal(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, values} ->
      case decode_literal(value_ast) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp decode_literal(_value) do
    validation_error("unsupported literal in flow script", %{})
  end

  defp existing_atom(value, context) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError ->
      validation_error("atom literal must already exist", %{
        context: context,
        atom: value
      })
  end

  defp build_flow(%{name: name, steps: steps}) do
    flow = Flow.new(name)

    steps
    |> Enum.reduce_while({:ok, flow}, fn step, {:ok, flow} ->
      try do
        {:cont, {:ok, Flow.step(flow, step.name, step.action, step.options)}}
      rescue
        exception ->
          {:halt,
           validation_error("invalid flow script step", %{
             step: step.name,
             reason: Exception.message(exception)
           })}
      end
    end)
  end

  defp validation_error(message, details) do
    {:error, Error.validation_error(message, details)}
  end
end
