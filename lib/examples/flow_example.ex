defmodule Jido.Examples.FlowExample do
  @moduledoc """
  Runnable examples for `Jido.Flow`.

  This module demonstrates the core flow mechanics:

  - linear action steps
  - fan-out from one upstream result into multiple downstream actions
  - fan-in through a Runic join
  - Runic retry policy around a Jido flow step
  - result, summary, and graph introspection
  - native Runic stateful components

  ## Checkout Flow

      {:ok, result} = Jido.Examples.FlowExample.run_checkout("cart_123")
      receipt = result.results.build_receipt |> List.first()

      receipt.receipt_id
      #=> "receipt-cart_123"

      receipt.total_cents
      #=> 6062

  The returned `Jido.Exec.Result` contains the current `Runic.Workflow`, grouped
  results, execution status, events, cycle count, and any error.

      Jido.Exec.summary(result)
      Jido.Flow.graph(result.workflow)

  ## Stateful Component

      {:ok, result} = Jido.Examples.FlowExample.run_running_total([2, 3, 5])
      10 in Runic.Workflow.raw_productions(result.workflow, :running_total)
      #=> true
  """

  alias Jido.Exec
  alias Jido.Exec.Result
  alias Jido.Flow

  alias Jido.Examples.FlowExample.{
    BuildReceipt,
    CalculateTax,
    LoadCart,
    PriceCart,
    ReserveInventory
  }

  alias Runic.Workflow

  require Runic

  @doc """
  Builds a checkout flow.

  Runtime input starts at `:load_cart`, fans out to pricing and inventory
  reservation, then joins tax and inventory results into a receipt.
  """
  @spec checkout_flow() :: Flow.t()
  def checkout_flow do
    Flow.new(:checkout)
    |> Flow.step(:load_cart, LoadCart)
    |> Flow.step(:price_cart, PriceCart, after: :load_cart)
    |> Flow.step(:reserve_inventory, ReserveInventory,
      after: :load_cart,
      exec_opts: [max_retries: 1, backoff: 0, log_level: :emergency]
    )
    |> Flow.step(:calculate_tax, CalculateTax,
      after: :price_cart,
      params: %{tax_bps: 825}
    )
    |> Flow.step(:build_receipt, BuildReceipt, after: [:calculate_tax, :reserve_inventory])
  end

  @doc """
  Runs the checkout flow to quiescence.
  """
  @spec run_checkout(String.t()) :: {:ok, Result.t()} | {:error, Result.t()}
  def run_checkout(cart_id \\ "cart_123") when is_binary(cart_id) do
    reset_inventory_attempts(cart_id)

    try do
      Exec.run(checkout_flow(), %{cart_id: cart_id}, max_cycles: 10)
    after
      reset_inventory_attempts(cart_id)
    end
  end

  @doc """
  Returns a compact view of a flow result.
  """
  @spec inspect_result(Result.t()) :: map()
  def inspect_result(%Result{} = result) do
    %{
      status: result.status,
      cycles: result.cycles,
      results: Exec.results(result),
      summary: Exec.summary(result),
      graph: Flow.graph(result.workflow)
    }
  end

  @doc """
  Builds a stateful running-total flow using a native Runic accumulator.
  """
  @spec running_total_flow() :: Flow.t()
  def running_total_flow do
    accumulator =
      Runic.accumulator(0, fn value, total -> total + value end, name: :running_total)

    Flow.new(:running_total)
    |> Flow.component(:running_total, accumulator)
  end

  @doc """
  Runs a stateful accumulator repeatedly, resuming from the previous workflow.
  """
  @spec run_running_total(nonempty_list(integer())) :: {:ok, Result.t()} | {:error, Result.t()}
  def run_running_total(values \\ [2, 3, 5])

  def run_running_total([first | rest]) do
    case Exec.run(running_total_flow(), first) do
      {:ok, %Result{} = result} -> resume_running_total(result, rest)
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp resume_running_total(%Result{} = result, []) do
    {:ok, result}
  end

  defp resume_running_total(%Result{workflow: %Workflow{} = workflow}, [value | rest]) do
    case workflow |> Flow.from_workflow() |> Exec.run(value) do
      {:ok, %Result{} = result} -> resume_running_total(result, rest)
      {:error, %Result{} = result} -> {:error, result}
    end
  end

  defp reset_inventory_attempts(cart_id) do
    :persistent_term.erase({ReserveInventory, cart_id})
  end

  defmodule LoadCart do
    @moduledoc false
    use Jido.Action,
      name: "flow_example_load_cart",
      schema: Zoi.object(%{cart_id: Zoi.string()}),
      output_schema:
        Zoi.object(%{
          cart_id: Zoi.string(),
          items:
            Zoi.list(
              Zoi.object(%{
                sku: Zoi.string(),
                quantity: Zoi.integer(),
                unit_price_cents: Zoi.integer()
              })
            )
        })

    @impl true
    def run(%{cart_id: cart_id}, _context) do
      {:ok,
       %{
         cart_id: cart_id,
         items: [
           %{sku: "book", quantity: 2, unit_price_cents: 1_200},
           %{sku: "lamp", quantity: 1, unit_price_cents: 3_200}
         ]
       }}
    end
  end

  defmodule PriceCart do
    @moduledoc false
    use Jido.Action,
      name: "flow_example_price_cart",
      schema:
        Zoi.object(%{
          cart_id: Zoi.string(),
          items:
            Zoi.list(
              Zoi.object(%{
                sku: Zoi.string(),
                quantity: Zoi.integer(),
                unit_price_cents: Zoi.integer()
              })
            )
        }),
      output_schema:
        Zoi.object(%{
          cart_id: Zoi.string(),
          subtotal_cents: Zoi.integer()
        })

    @impl true
    def run(%{cart_id: cart_id, items: items}, _context) do
      subtotal =
        Enum.reduce(items, 0, fn item, acc ->
          acc + item.quantity * item.unit_price_cents
        end)

      {:ok, %{cart_id: cart_id, subtotal_cents: subtotal}}
    end
  end

  defmodule ReserveInventory do
    @moduledoc false
    use Jido.Action,
      name: "flow_example_reserve_inventory",
      schema:
        Zoi.object(%{
          cart_id: Zoi.string(),
          items:
            Zoi.list(
              Zoi.object(%{
                sku: Zoi.string(),
                quantity: Zoi.integer(),
                unit_price_cents: Zoi.integer()
              })
            )
        }),
      output_schema:
        Zoi.object(%{
          cart_id: Zoi.string(),
          reserved?: Zoi.boolean(),
          hold_id: Zoi.string(),
          attempts: Zoi.integer()
        })

    @impl true
    def run(%{cart_id: cart_id}, _context) do
      attempts = :persistent_term.get({__MODULE__, cart_id}, 0) + 1
      :persistent_term.put({__MODULE__, cart_id}, attempts)

      if attempts == 1 do
        {:error, :inventory_temporarily_locked}
      else
        {:ok,
         %{
           cart_id: cart_id,
           reserved?: true,
           hold_id: "hold-#{cart_id}",
           attempts: attempts
         }}
      end
    end
  end

  defmodule CalculateTax do
    @moduledoc false
    use Jido.Action,
      name: "flow_example_calculate_tax",
      schema:
        Zoi.object(%{
          cart_id: Zoi.string(),
          subtotal_cents: Zoi.integer(),
          tax_bps: Zoi.integer() |> Zoi.default(0)
        }),
      output_schema:
        Zoi.object(%{
          cart_id: Zoi.string(),
          subtotal_cents: Zoi.integer(),
          tax_cents: Zoi.integer(),
          total_cents: Zoi.integer()
        })

    @impl true
    def run(%{cart_id: cart_id, subtotal_cents: subtotal, tax_bps: tax_bps}, _context) do
      tax = div(subtotal * tax_bps + 5_000, 10_000)

      {:ok,
       %{
         cart_id: cart_id,
         subtotal_cents: subtotal,
         tax_cents: tax,
         total_cents: subtotal + tax
       }}
    end
  end

  defmodule BuildReceipt do
    @moduledoc false
    use Jido.Action,
      name: "flow_example_build_receipt",
      schema: Zoi.object(%{input: Zoi.list(Zoi.any())}),
      output_schema:
        Zoi.object(%{
          receipt_id: Zoi.string(),
          cart_id: Zoi.string(),
          total_cents: Zoi.integer(),
          hold_id: Zoi.string(),
          reserved?: Zoi.boolean()
        })

    @impl true
    def run(%{input: joined_results}, _context) do
      priced = Enum.find(joined_results, &Map.has_key?(&1, :total_cents))
      inventory = Enum.find(joined_results, &Map.has_key?(&1, :hold_id))

      {:ok,
       %{
         receipt_id: "receipt-#{priced.cart_id}",
         cart_id: priced.cart_id,
         total_cents: priced.total_cents,
         hold_id: inventory.hold_id,
         reserved?: inventory.reserved?
       }}
    end
  end
end
