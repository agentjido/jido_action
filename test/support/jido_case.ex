defmodule JidoTest.ActionCase do
  @moduledoc """
  Test case helper module providing common test functionality for Jido tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import JidoTest.ActionCase
      import JidoTest.FlowScriptAssertions
    end
  end

  @doc """
  Suppresses Logger output from the current test process while executing `fun`.

  Use this around paths that intentionally exercise expected failures. Prefer
  explicit assertions on returned errors over assertions on log text.
  """
  def silence_logger(fun) when is_function(fun, 0) do
    Logger.put_process_level(self(), :none)

    try do
      fun.()
    after
      Logger.delete_process_level(self())
    end
  end

  @doc """
  Creates a unique module name under the calling test module.
  """
  defmacro unique_module(prefix) do
    namespace = __CALLER__.module

    quote bind_quoted: [namespace: namespace, prefix: prefix] do
      Module.concat(namespace, :"#{prefix}#{System.unique_integer([:positive])}")
    end
  end

  @doc """
  Creates a runtime module and asserts that compilation succeeded.
  """
  def create_module(module, quoted) do
    assert {:module, ^module, _bytecode, _term} =
             Module.create(module, quoted, Macro.Env.location(__ENV__))
  end
end

defmodule JidoTest.FlowScriptAssertions do
  @moduledoc false

  import ExUnit.Assertions

  alias Jido.Flow
  alias Jido.Flow.Script

  @script_atoms [
    :scripted_combination,
    :scripted_render,
    :scripted_render_all,
    :scripted_render_empty,
    :scripted_round_trip,
    :bad,
    :add,
    :add_one,
    :add_two,
    :amount,
    :after,
    :cart_id,
    :checkout,
    :collect_payload,
    :context,
    :counter,
    :dashboard,
    :default,
    :dep,
    :double,
    :double_each,
    :enterprise,
    :enterprise?,
    :fallback,
    :format,
    :format_receipt,
    :from,
    :in,
    :input,
    :init,
    :item,
    :items,
    :items_debug,
    :label,
    :line_totals,
    :limit,
    :load_items,
    :load_order,
    :load_profile,
    :load_settings,
    :load_user,
    :loaded_items,
    :map,
    :matches?,
    :mfa,
    :output,
    :order,
    :over,
    :path,
    :params,
    :premium,
    :premium?,
    :profile,
    :route,
    :run,
    :settings,
    :source,
    :standard,
    :sum,
    :subtotal,
    :trace_id,
    :user,
    :user_id,
    :value,
    :wait_for,
    :JidoTest,
    :TestActions,
    :Add,
    :BasicAction,
    :Double,
    :FlowFunctions,
    :LoadItems,
    :NoParamsAction
  ]

  def script_atoms(extra \\ []), do: Enum.uniq(@script_atoms ++ extra)

  def flow_script(body, opts \\ []) when is_binary(body) do
    name = Keyword.get(opts, :name, :scripted_combination)

    """
    flow #{inspect(name)} do
    #{indent_body(body)}
    end
    """
  end

  def parse_flow_script!(body, opts \\ []) do
    body
    |> flow_script(opts)
    |> Script.parse!(allowed_atoms: script_atoms(Keyword.get(opts, :atoms, [])))
  end

  def assert_script_round_trip(body, opts \\ []) do
    atoms = script_atoms(Keyword.get(opts, :atoms, []))
    flow = parse_flow_script!(body, opts)
    projected = Script.to_script(flow)
    reparsed = Script.parse!(projected, allowed_atoms: atoms)

    assert Flow.to_map(reparsed) == Flow.to_map(flow)

    {flow, projected}
  end

  def assert_script_error(body, expected, opts \\ []) do
    assert {:error, %ArgumentError{message: message}} =
             body
             |> flow_script(opts)
             |> Script.parse(allowed_atoms: script_atoms(Keyword.get(opts, :atoms, [])))

    assert message =~ expected
  end

  defp indent_body(body) do
    body
    |> String.trim()
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end
end
