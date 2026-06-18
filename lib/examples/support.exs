{:ok, _apps} = Application.ensure_all_started(:jido_action)

defmodule Jido.Examples.Support do
  def ensure! do
    {:ok, _apps} = Application.ensure_all_started(:jido_action)
    :ok
  end

  def quiet_logs! do
    Logger.configure(level: :error)
    :ok
  end

  def print(title, value) do
    IO.puts("\n#{title}")

    IO.inspect(value,
      label: "result",
      limit: :infinity,
      printable_limit: :infinity,
      charlists: :as_lists
    )
  end

  def expect(value, expected) do
    if value != expected do
      raise "expected #{inspect(expected)}, got #{inspect(value)}"
    end

    value
  end

  def ok!({:ok, result}), do: result
  def ok!(other), do: raise("expected {:ok, result}, got #{inspect(other)}")

  def error!({:error, result}), do: result
  def error!(other), do: raise("expected {:error, result}, got #{inspect(other)}")

  def with_flaky_key(fun) when is_function(fun, 1) do
    key = System.unique_integer([:positive])
    term_key = {Jido.Examples.Actions.Flaky, key}
    :persistent_term.erase(term_key)

    try do
      fun.(key)
    after
      :persistent_term.erase(term_key)
    end
  end

  def capture_io(fun) when is_function(fun, 0) do
    {:ok, io} = StringIO.open("")
    caller_group_leader = Process.group_leader()

    try do
      Process.group_leader(self(), io)
      result = fun.()
      {_input, output} = StringIO.contents(io)
      {result, output}
    after
      Process.group_leader(self(), caller_group_leader)
    end
  end

  def example_files do
    __ENV__.file
    |> Path.dirname()
    |> Path.join("[0-9][0-9]_*.exs")
    |> Path.wildcard()
    |> Enum.sort()
  end

  def raw_add_workflow do
    Jido.Flow.from_action(Jido.Examples.Actions.Add, %{amount: 2}, name: :raw_add)
    |> Jido.Flow.to_workflow()
  end
end

defmodule Jido.Examples.Functions do
  def identity(value), do: value
  def double(value), do: value * 2
  def triple(value), do: value * 3
  def sum(value, acc), do: value + acc
  def count(_value, acc), do: acc + 1
  def append(value, acc), do: acc ++ [value]
  def item_total(%{price_cents: price, quantity: quantity}), do: price * quantity
  def extract_value(%{value: value}), do: value
end

defmodule Jido.Examples.Actions.Add do
  use Jido.Action,
    name: "add",
    schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(1)}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  def run(%{value: value, amount: amount}, _context), do: {:ok, %{value: value + amount}}
end

defmodule Jido.Examples.Actions.Double do
  use Jido.Action,
    name: "double",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  def run(%{value: value}, _context), do: {:ok, %{value: value * 2}}
end

defmodule Jido.Examples.Actions.FinalizeTotal do
  use Jido.Action,
    name: "finalize_total",
    schema: Zoi.object(%{input: Zoi.integer()}),
    output_schema: Zoi.object(%{total: Zoi.integer()})

  def run(%{input: total}, _context), do: {:ok, %{total: total}}
end

defmodule Jido.Examples.Actions.SumJoined do
  use Jido.Action,
    name: "sum_joined",
    schema: Zoi.object(%{input: Zoi.list(Zoi.map(Zoi.any(), Zoi.any()))}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  def run(%{input: values}, _context) do
    total = Enum.reduce(values, 0, fn %{value: value}, acc -> acc + value end)
    {:ok, %{value: total}}
  end
end

defmodule Jido.Examples.Actions.ContextEcho do
  use Jido.Action,
    name: "context_echo",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema:
      Zoi.object(%{
        value: Zoi.integer(),
        static: Zoi.any() |> Zoi.optional(),
        runtime: Zoi.any() |> Zoi.optional(),
        tenant: Zoi.any() |> Zoi.optional()
      })

  def run(%{value: value}, context) do
    {:ok,
     %{
       value: value,
       static: Map.get(context, :static),
       runtime: Map.get(context, :runtime),
       tenant: Map.get(context, :tenant)
     }}
  end
end

defmodule Jido.Examples.Actions.CountInput do
  use Jido.Action,
    name: "count_input",
    schema: Zoi.object(%{input: Zoi.list(Zoi.integer())}),
    output_schema: Zoi.object(%{count: Zoi.integer()})

  def run(%{input: values}, _context), do: {:ok, %{count: length(values)}}
end

defmodule Jido.Examples.Actions.NormalizeOrder do
  use Jido.Action,
    name: "normalize_order",
    schema: Zoi.object(%{order_id: Zoi.string(), items: Zoi.list(Zoi.any())}),
    output_schema: Zoi.object(%{order_id: Zoi.string(), items: Zoi.list(Zoi.any())})

  def run(%{order_id: order_id, items: items}, _context) do
    {:ok, %{order_id: order_id, items: items}}
  end
end

defmodule Jido.Examples.Actions.PriceOrder do
  use Jido.Action,
    name: "price_order",
    schema: Zoi.object(%{order_id: Zoi.string(), items: Zoi.list(Zoi.any())}),
    output_schema:
      Zoi.object(%{
        order_id: Zoi.string(),
        items: Zoi.list(Zoi.any()),
        subtotal_cents: Zoi.integer()
      })

  def run(%{order_id: order_id, items: items}, _context) do
    subtotal =
      Enum.reduce(items, 0, fn %{price_cents: price, quantity: quantity}, acc ->
        acc + price * quantity
      end)

    {:ok, %{order_id: order_id, items: items, subtotal_cents: subtotal}}
  end
end

defmodule Jido.Examples.Actions.TaxOrder do
  use Jido.Action,
    name: "tax_order",
    schema:
      Zoi.object(%{
        order_id: Zoi.string(),
        items: Zoi.list(Zoi.any()) |> Zoi.optional(),
        subtotal_cents: Zoi.integer(),
        tax_bps: Zoi.integer() |> Zoi.default(825)
      }),
    output_schema:
      Zoi.object(%{
        order_id: Zoi.string(),
        subtotal_cents: Zoi.integer(),
        tax_cents: Zoi.integer(),
        total_cents: Zoi.integer()
      })

  def run(%{order_id: order_id, subtotal_cents: subtotal, tax_bps: tax_bps}, _context) do
    tax = div(subtotal * tax_bps, 10_000)

    {:ok,
     %{order_id: order_id, subtotal_cents: subtotal, tax_cents: tax, total_cents: subtotal + tax}}
  end
end

defmodule Jido.Examples.Actions.FormatOrder do
  use Jido.Action,
    name: "format_order",
    schema:
      Zoi.object(%{
        order_id: Zoi.string(),
        subtotal_cents: Zoi.integer(),
        tax_cents: Zoi.integer(),
        total_cents: Zoi.integer()
      }),
    output_schema: Zoi.object(%{summary: Zoi.string(), total_cents: Zoi.integer()})

  def run(%{order_id: order_id, total_cents: total}, _context) do
    {:ok, %{summary: "order #{order_id}: #{total} cents", total_cents: total}}
  end
end

defmodule Jido.Examples.Actions.EnrichTenant do
  use Jido.Action,
    name: "enrich_tenant",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer(), tenant: Zoi.any()})

  def run(%{value: value}, context), do: {:ok, %{value: value, tenant: Map.get(context, :tenant)}}
end

defmodule Jido.Examples.Actions.Divide do
  use Jido.Action,
    name: "divide",
    schema: Zoi.object(%{value: Zoi.integer(), divisor: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  def run(%{divisor: 0}, _context), do: {:error, "cannot divide by zero"}
  def run(%{value: value, divisor: divisor}, _context), do: {:ok, %{value: div(value, divisor)}}
end

defmodule Jido.Examples.Actions.Fail do
  use Jido.Action,
    name: "fail",
    schema: Zoi.object(%{}),
    output_schema: Zoi.object(%{})

  def run(_params, _context), do: {:error, "planned failure"}
end

defmodule Jido.Examples.Actions.Flaky do
  use Jido.Action,
    name: "flaky",
    schema: Zoi.object(%{key: Zoi.any()}),
    output_schema: Zoi.object(%{attempts: Zoi.integer()})

  def run(%{key: key}, _context) do
    attempts = :persistent_term.get({__MODULE__, key}, 0) + 1
    :persistent_term.put({__MODULE__, key}, attempts)

    if attempts < 2 do
      {:error, :transient_error}
    else
      {:ok, %{attempts: attempts}}
    end
  end
end

defmodule Jido.Examples.Actions.AlwaysFail do
  use Jido.Action,
    name: "always_fail",
    schema: Zoi.object(%{key: Zoi.any() |> Zoi.optional()}),
    output_schema: Zoi.object(%{})

  def run(_params, _context), do: {:error, :still_failing}
end

defmodule Jido.Examples.Actions.Slow do
  use Jido.Action,
    name: "slow",
    schema: Zoi.object(%{delay: Zoi.integer() |> Zoi.default(50)}),
    output_schema: Zoi.object(%{done: Zoi.boolean()})

  def run(%{delay: delay}, _context) do
    Process.sleep(delay)
    {:ok, %{done: true}}
  end
end

defmodule Jido.Examples.Actions.InvalidOutput do
  use Jido.Action,
    name: "invalid_output",
    schema: Zoi.object(%{}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  def run(_params, _context), do: {:ok, %{value: "not an integer"}}
end

defmodule Jido.Examples.Actions.UnexpectedReturn do
  use Jido.Action,
    name: "unexpected_return",
    schema: Zoi.object(%{}),
    output_schema: Zoi.object(%{})

  def run(_params, _context), do: %{bare: :map}
end

defmodule Jido.Examples.Actions.RaiseAction do
  use Jido.Action,
    name: "raise_action",
    schema: Zoi.object(%{}),
    output_schema: Zoi.object(%{})

  def run(_params, _context), do: raise("raised from action")
end

defmodule Jido.Examples.Actions.ThrowAction do
  use Jido.Action,
    name: "throw_action",
    schema: Zoi.object(%{}),
    output_schema: Zoi.object(%{})

  def run(_params, _context), do: throw("thrown from action")
end

defmodule Jido.Examples.Actions.KillAction do
  use Jido.Action,
    name: "kill_action",
    schema: Zoi.object(%{}),
    output_schema: Zoi.object(%{})

  def run(_params, _context) do
    Process.exit(self(), :kill)
    {:ok, %{}}
  end
end

defmodule Jido.Examples.Actions.IOAction do
  use Jido.Action,
    name: "io_action",
    schema: Zoi.object(%{message: Zoi.string()}),
    output_schema: Zoi.object(%{message: Zoi.string()})

  def run(%{message: message}, _context) do
    IO.puts(message)
    {:ok, %{message: message}}
  end
end

defmodule Jido.Examples.Actions.StreamAction do
  alias Jido.Action.Output

  use Jido.Action,
    name: "stream_action",
    schema: Zoi.object(%{limit: Zoi.integer()})

  def run(%{limit: limit}, _context) do
    stream = Stream.map(1..limit, &(&1 * 2))
    {:ok, Output.stream(stream, meta: %{source: :range, limit: limit})}
  end
end

defmodule Jido.Examples.Actions.RawPayload do
  alias Jido.Action.Output

  use Jido.Action,
    name: "raw_payload",
    schema: Zoi.object(%{payload: Zoi.any()})

  def run(%{payload: payload}, _context) do
    {:ok, Output.raw(payload, meta: %{source: :external})}
  end
end

defmodule Jido.Examples.Actions.BatchOutput do
  alias Jido.Action.Output

  use Jido.Action,
    name: "batch_output",
    schema: Zoi.object(%{count: Zoi.integer()})

  def run(%{count: count}, _context) do
    values = Enum.map(1..count, &%{index: &1, value: &1 * 10})
    {:ok, Output.batch(values, meta: %{count: count})}
  end
end

defmodule Jido.Examples.Actions.OpaqueDirective do
  alias Jido.Action.Output

  use Jido.Action,
    name: "opaque_directive",
    schema: Zoi.object(%{})

  def run(_params, _context) do
    handle = {:external_handle, System.unique_integer([:positive])}
    {:ok, Output.opaque(handle, meta: %{owner: :external_system}), %{route: :inspect}}
  end
end

defmodule Jido.Examples.Actions.DirectiveAction do
  use Jido.Action,
    name: "directive_action",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  def run(%{value: value}, _context), do: {:ok, %{value: value}, %{route: :next}}
end

defmodule Jido.Examples.Actions.ErrorDirectiveAction do
  use Jido.Action,
    name: "error_directive_action",
    schema: Zoi.object(%{}),
    output_schema: Zoi.object(%{})

  def run(_params, _context), do: {:error, :needs_review, %{route: :fallback}}
end
