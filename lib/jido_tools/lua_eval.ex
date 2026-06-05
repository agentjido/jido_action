defmodule Jido.Tools.LuaEval do
  @moduledoc """
  Execute a Lua code string in a sandboxed VM and return the values.

  ## Features

  - **Safe by default:** Uses Lua.ex sandbox defaults to disable unsafe functions
  - **Timeout protection:** Configurable timeout with task isolation
  - **Call-depth protection:** Optional recursion guard for nested Lua calls
  - **Global injection:** Pass Elixir values into the Lua environment
  - **Flexible returns:** Return all values or just the first one

  ## Security

  By default, the following unsafe Lua libraries are disabled:
  - `os` (getenv, execute, exit, etc.)
  - `io` and `file`
  - `package`, `require`, `dofile`
  - `load`, `loadfile`, `loadstring`

  Safe libraries remain enabled:
  - `string`, `math`, `table`
  - Basic Lua operations

  Set `enable_unsafe_libs: true` to disable Lua.ex capability sandboxing (use with
  caution). Lua.ex 1.0 still has no host shell or host filesystem access.
  Set `max_call_depth` to a positive integer to cap nested Lua function calls.

  ## Examples

      # Simple arithmetic
      iex> Jido.Tools.LuaEval.run(%{code: "return 2 + 2"}, %{})
      {:ok, %{results: [4]}}

      # With globals
      iex> Jido.Tools.LuaEval.run(%{
        code: "return x + 5",
        globals: %{"x" => 10}
      }, %{})
      {:ok, %{results: [15]}}

      # Return first value only
      iex> Jido.Tools.LuaEval.run(%{
        code: "return 1, 2, 3",
        return_mode: :first
      }, %{})
      {:ok, %{result: 1}}

      # Timeout protection
      iex> Jido.Tools.LuaEval.run(%{
        code: "while true do end",
        timeout_ms: 50
      }, %{})
      {:error, %Jido.Action.Error.TimeoutError{timeout: 50}}
  """

  use Private

  alias Jido.Action.Error

  use Jido.Action,
    name: "lua_eval",
    description: "Execute a Lua code string in a sandboxed VM and return the values.",
    category: "scripting",
    vsn: "0.1.0",
    schema: [
      code: [
        type: :string,
        required: true,
        doc: "Lua code to execute (typically ends with `return ...` to produce values)."
      ],
      globals: [
        type: :map,
        default: %{},
        doc: "Map of global variables to inject into Lua state. Keys can be atoms or strings."
      ],
      return_mode: [
        type: {:in, [:list, :first]},
        default: :list,
        doc:
          "Shape of output: :list returns all values under `results`, :first returns only the first under `result`."
      ],
      enable_unsafe_libs: [
        type: :boolean,
        default: false,
        doc: "Enable unsafe libs (os/package/require/etc.) by disabling sandboxing."
      ],
      timeout_ms: [
        type: :non_neg_integer,
        default: 1000,
        doc: "Execution timeout in milliseconds."
      ],
      max_call_depth: [
        type: :non_neg_integer,
        default: 0,
        doc: "Maximum nested Lua call depth (0 = disabled / infinity)."
      ],
      max_heap_bytes: [
        type: :non_neg_integer,
        default: 0,
        doc: "Per-process heap limit in bytes (0 = disabled)."
      ]
    ],
    output_schema: []

  @impl true
  def run(params, _context) do
    if Code.ensure_loaded?(Lua) do
      timeout_ms = Map.get(params, :timeout_ms, 1000)
      parent = self()
      ref = make_ref()

      {:ok, pid} =
        Task.Supervisor.start_child(Jido.Action.TaskSupervisor, fn ->
          send(parent, {:lua_eval_result, ref, do_run(params)})
        end)

      monitor_ref = Process.monitor(pid)

      case await_lua_result(ref, pid, monitor_ref, timeout_ms) do
        {:ok, result} ->
          cleanup_lua_task(ref, monitor_ref)
          result

        {:exit, reason} ->
          cleanup_lua_task(ref, monitor_ref)
          return_error(:lua_error, "Lua task exited: #{inspect(reason)}")

        :timeout ->
          _ = Process.exit(pid, :kill)
          wait_for_lua_down(monitor_ref, pid, 100)
          cleanup_lua_task(ref, monitor_ref)
          timeout_error(timeout_ms)
      end
    else
      msg =
        "Lua library (:lua) is not available. Add {:lua, \"~> 1.0.0-rc\"} to your deps and run mix deps.get"

      return_error(:dependency_error, msg)
    end
  end

  private do
    defp await_lua_result(ref, pid, monitor_ref, timeout_ms) do
      receive do
        {:lua_eval_result, ^ref, result} ->
          {:ok, result}

        {:DOWN, ^monitor_ref, :process, ^pid, :normal} ->
          wait_for_lua_result(ref, 100)

        {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
          {:exit, reason}
      after
        timeout_ms ->
          :timeout
      end
    end

    defp wait_for_lua_result(ref, wait_ms) do
      receive do
        {:lua_eval_result, ^ref, result} -> {:ok, result}
      after
        wait_ms -> {:exit, :normal}
      end
    end

    defp wait_for_lua_down(monitor_ref, pid, wait_ms) do
      receive do
        {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
      after
        wait_ms -> :ok
      end
    end

    defp cleanup_lua_task(ref, monitor_ref) do
      Process.demonitor(monitor_ref, [:flush])
      flush_lua_results(ref)
    end

    defp flush_lua_results(ref) do
      receive do
        {:lua_eval_result, ^ref, _result} ->
          flush_lua_results(ref)
      after
        0 -> :ok
      end
    end
  end

  defp do_run(params) do
    code = Map.fetch!(params, :code)
    globals = Map.get(params, :globals, %{})
    return_mode = Map.get(params, :return_mode, :list)
    enable_unsafe_libs = Map.get(params, :enable_unsafe_libs, false)
    max_call_depth = Map.get(params, :max_call_depth, 0)
    max_heap_bytes = Map.get(params, :max_heap_bytes, 0)

    if is_integer(max_heap_bytes) and max_heap_bytes > 0 do
      :erlang.process_flag(:max_heap_size, %{size: max_heap_bytes, kill: true})
    end

    try do
      lua =
        enable_unsafe_libs
        |> lua_options(max_call_depth)
        |> Lua.new()
        |> inject_globals(globals)

      {values, _state} = Lua.eval!(lua, code)

      result =
        case return_mode do
          :first -> %{result: List.first(values)}
          _ -> %{results: values}
        end

      {:ok, result}
    rescue
      e in Lua.CompilerException ->
        return_error(:compile_error, Exception.message(e))

      e in Lua.RuntimeException ->
        return_error(:lua_error, Exception.message(e))

      e ->
        return_error(:lua_error, Exception.message(e))
    end
  end

  defp lua_options(enable_unsafe_libs, max_call_depth) do
    []
    |> maybe_disable_sandbox(enable_unsafe_libs)
    |> maybe_put_max_call_depth(max_call_depth)
  end

  defp maybe_disable_sandbox(opts, true), do: Keyword.put(opts, :sandboxed, [])
  defp maybe_disable_sandbox(opts, _), do: opts

  defp maybe_put_max_call_depth(opts, max_call_depth)
       when is_integer(max_call_depth) and max_call_depth > 0 do
    Keyword.put(opts, :max_call_depth, max_call_depth)
  end

  defp maybe_put_max_call_depth(opts, _), do: opts

  defp inject_globals(lua, globals) do
    Enum.reduce(globals || %{}, lua, fn {key, value}, acc ->
      {encoded, acc2} = Lua.encode!(acc, value)
      path = if is_list(key), do: key, else: [key]
      Lua.set!(acc2, path, encoded)
    end)
  end

  defp return_error(type, message) do
    {:error,
     Error.execution_error(message, %{
       type: type,
       reason: %{type: type, message: message}
     })}
  end

  defp timeout_error(timeout_ms) do
    {:error,
     Error.timeout_error("Lua execution timed out after #{timeout_ms}ms", %{
       timeout: timeout_ms,
       reason: %{type: :timeout, timeout_ms: timeout_ms}
     })}
  end
end
