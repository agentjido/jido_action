defmodule JidoTest.TestActions do
  @moduledoc false

  alias Jido.Action
  alias Jido.Action.Error

  defmodule BasicAction do
    @moduledoc false
    use Action,
      name: "basic_action",
      description: "A basic action for testing",
      schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context) do
      {:ok, %{value: value}}
    end
  end

  defmodule EchoAction do
    @moduledoc false
    use Action,
      name: "echo_action",
      description: "Echoes normalized params and context for execution tests"

    def run(params, context) do
      {:ok, %{params: params, context: context}}
    end
  end

  defmodule RawResultAction do
    @moduledoc false
    use Action,
      name: "raw_result_action",
      schema: Zoi.object(%{value: Zoi.integer()})

    @dialyzer {:nowarn_function, run: 2}
    def run(%{value: value}, _context) do
      %{value: value}
    end
  end

  defmodule NoSchema do
    @moduledoc false
    use Action,
      name: "add_two",
      description: "Adds 2 to the input value"

    def run(%{value: value}, _context), do: {:ok, %{result: value + 2}}

    # Allow no params
    def run(_params, _context), do: {:ok, %{result: "No params"}}
  end

  defmodule NoParamsAction do
    @moduledoc false
    use Action,
      name: "no_params_action",
      description: "A action with no parameters"

    def run(_params, _context), do: {:ok, %{result: "No params"}}
  end

  defmodule OutputSchemaAction do
    @moduledoc false
    use Action,
      name: "output_schema_action",
      description: "Action that validates output with schema",
      schema: Zoi.object(%{input: Zoi.string()}),
      output_schema: Zoi.object(%{result: Zoi.string(), length: Zoi.integer()})

    def run(%{input: input}, _context) do
      {:ok, %{result: String.upcase(input), length: String.length(input), extra: "not validated"}}
    end
  end

  defmodule InvalidOutputAction do
    @moduledoc false
    use Action,
      name: "invalid_output_action",
      description: "Action that returns invalid output",
      output_schema: Zoi.object(%{required_field: Zoi.string()})

    def run(_params, _context) do
      {:ok, %{wrong_field: "this will fail validation"}}
    end
  end

  defmodule NoOutputSchemaAction do
    @moduledoc false
    use Action,
      name: "no_output_schema_action",
      description: "Action without output schema"

    def run(_params, _context) do
      {:ok, %{anything: "goes", here: 123}}
    end
  end

  defmodule OutputCallbackAction do
    @moduledoc false
    use Action,
      name: "output_callback_action",
      description: "Action that uses output validation callbacks",
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{input: input}, _context) do
      {:ok, %{value: input}}
    end
  end

  defmodule FullAction do
    @moduledoc false
    use Action,
      name: "full_action",
      description: "A full action for testing",
      schema: Zoi.object(%{a: Zoi.integer(), b: Zoi.integer()})

    @impl true
    def run(params, _context) do
      result = params.a + params.b
      {:ok, Map.put(params, :result, result)}
    end
  end

  defmodule CompensateAction do
    @moduledoc false
    use Action,
      name: "compensate_action",
      description: "Action that tests compensation behavior",
      schema:
        Zoi.object(%{
          should_fail: Zoi.boolean(),
          compensation_should_fail: Zoi.boolean() |> Zoi.default(false),
          delay: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0),
          test_value: Zoi.string() |> Zoi.default("")
        })

    def run(%{should_fail: true}, _context) do
      {:error, Error.execution_error("Intentional failure")}
    end

    def run(_params, _context) do
      {:ok, %{result: "CompensateAction completed"}}
    end
  end

  defmodule ErrorAction do
    @moduledoc false
    use Action, name: "error_action"

    def run(%{error_type: :validation}, _context) do
      {:error, "Validation error"}
    end

    def run(%{error_type: :argument}, _context) do
      raise ArgumentError, message: "Argument error"
    end

    def run(%{error_type: :runtime}, _context) do
      raise RuntimeError, message: "Runtime error"
    end

    def run(%{error_type: :custom}, _context) do
      raise "Custom error"
    end

    def run(%{type: :throw}, _context) do
      throw("Action threw an error")
    end

    def run(_params, _context), do: {:error, "Exec failed"}
  end

  defmodule NormalExitAction do
    @moduledoc false
    use Action,
      name: "normal_exit_action",
      description: "Exits normally"

    def run(_params, _context) do
      Process.exit(self(), :normal)
      {:ok, %{result: "This should never be returned"}}
    end
  end

  defmodule KilledAction do
    @moduledoc false
    use Action,
      name: "killed_action",
      description: "Kills the process"

    def run(_params, _context) do
      # Simulate some work before getting killed
      Process.sleep(50)
      Process.exit(self(), :kill)

      # This line will never be reached
      {:ok, %{result: "This should never be returned"}}
    end
  end

  defmodule SlowKilledAction do
    @moduledoc false
    use Jido.Action,
      name: "slow_killed_action",
      schema: Zoi.object(%{})

    @impl true
    @dialyzer {:nowarn_function, run: 2}
    def run(_params, _context) do
      receive do
        :never -> :ok
      end
    end
  end

  defmodule SpawnerAction do
    @moduledoc false
    use Action,
      name: "spawner_action",
      description: "Spawns a new process"

    def run(%{count: count}, _context) do
      for _ <- 1..count do
        spawn(fn -> Process.sleep(10_000) end)
      end

      {:ok, %{result: "Multi-process action completed"}}
    end
  end

  defmodule NakedTaskAction do
    @moduledoc false
    use Action,
      name: "naked_task_action",
      description: "Spawns tasks without linking into OTP"

    def run(%{count: count}, _context) do
      _pids =
        for _ <- 1..count do
          spawn(fn ->
            Process.sleep(:infinity)
          end)
        end

      {:ok, %{result: "Multi-process action completed"}}
    end

    def run(_, context), do: run(%{count: 1}, context)
  end

  defmodule Add do
    @moduledoc false
    use Action,
      name: "add_one",
      description: "Adds 1 to the input value",
      schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(1)}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value, amount: amount}, _context) do
      {:ok, %{value: value + amount}}
    end
  end

  defmodule Double do
    @moduledoc false
    use Action,
      name: "double",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: value * 2}}
  end

  defmodule SumJoined do
    @moduledoc false
    use Action,
      name: "sum_joined",
      schema: Zoi.object(%{input: Zoi.list(Zoi.map(Zoi.any(), Zoi.any()))}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{input: values}, _context) do
      total = Enum.reduce(values, 0, fn %{value: value}, acc -> acc + value end)
      {:ok, %{value: total}}
    end
  end

  defmodule Fail do
    @moduledoc false
    use Action,
      name: "fail",
      schema: Zoi.object(%{}),
      output_schema: Zoi.object(%{})

    def run(_params, _context), do: {:error, "boom"}
  end

  defmodule Flaky do
    @moduledoc false
    use Action,
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

  defmodule Slow do
    @moduledoc false
    use Action,
      name: "slow",
      schema: Zoi.object(%{}),
      output_schema: Zoi.object(%{done: Zoi.boolean()})

    def run(_params, _context) do
      Process.sleep(200)
      {:ok, %{done: true}}
    end
  end

  defmodule ContextEcho do
    @moduledoc false
    use Action,
      name: "context_echo",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema:
        Zoi.object(%{
          value: Zoi.integer(),
          static: Zoi.boolean() |> Zoi.optional(),
          runtime: Zoi.boolean() |> Zoi.optional()
        })

    def run(%{value: value}, context) do
      {:ok,
       %{
         value: value,
         static: Map.get(context, :static),
         runtime: Map.get(context, :runtime)
       }}
    end
  end

  defmodule WithDirective do
    @moduledoc false
    use Action,
      name: "with_directive",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: value}, %{next: :flow}}
  end

  defmodule ErrorWithDirective do
    @moduledoc false
    use Action,
      name: "error_with_directive",
      schema: Zoi.object(%{}),
      output_schema: Zoi.object(%{})

    def run(_params, _context), do: {:error, :transient_error, %{next: :retry}}
  end

  defmodule InvalidFlowOutput do
    @moduledoc false
    use Action,
      name: "invalid_flow_output",
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(_params, _context), do: {:ok, %{value: "bad"}}
  end

  defmodule InvalidOutputWithDirective do
    @moduledoc false
    use Action,
      name: "invalid_output_with_directive",
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(_params, _context), do: {:ok, %{value: "bad"}, %{next: :repair}}
  end

  defmodule OptionalInput do
    @moduledoc false
    use Action,
      name: "optional_input",
      schema:
        Zoi.object(%{
          value: Zoi.integer(),
          label: Zoi.string() |> Zoi.optional()
        }),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: value}}
  end

  defmodule ManualNoSchema do
    @moduledoc false
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ScalarSchema do
    @moduledoc false
    def schema, do: Zoi.integer()
    def output_schema, do: Zoi.string()
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ValidateParamsError do
    @moduledoc false
    def run(params, _context), do: {:ok, params}
    def validate_params(_params), do: {:error, Error.validation_error("bad params")}
    def validate_output(output), do: {:ok, output}
  end

  defmodule InvalidValidateParamsReturn do
    @moduledoc false
    def run(params, _context), do: {:ok, params}
    def validate_params(_params), do: :ok
    def validate_output(output), do: {:ok, output}
  end

  defmodule InvalidValidateOutputReturn do
    @moduledoc false
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
    def validate_output(_output), do: :ok
  end

  defmodule UnexpectedReturn do
    @moduledoc false
    def run(_params, _context), do: :ok
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ErrorExceptionAction do
    @moduledoc false
    def run(_params, _context), do: {:error, RuntimeError.exception("direct failure")}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ErrorExceptionWithDirective do
    @moduledoc false
    def run(_params, _context),
      do: {:error, RuntimeError.exception("directive failure"), %{next: :retry}}

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ErrorTupleAction do
    @moduledoc false
    def run(_params, _context), do: {:error, {:bad, :shape}}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ErrorWithEmptyDirective do
    @moduledoc false
    def run(_params, _context), do: {:error, :empty_directive, []}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule EmptyDirective do
    @moduledoc false
    def run(params, _context), do: {:ok, params, []}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule RaisingAction do
    @moduledoc false
    def run(_params, _context), do: raise("boom")
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ErrorMapAction do
    @moduledoc false
    def run(_params, _context), do: {:error, %{message: "mapped failure", code: :mapped}}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule MissingRun do
    @moduledoc false
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule MissingValidateOutput do
    @moduledoc false
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
  end

  defmodule NotAnAction do
    @moduledoc false
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule NamedComponent do
    @moduledoc false
    defstruct [:name, :hash]
  end

  defmodule Multiply do
    @moduledoc false
    use Action,
      name: "multiply",
      description: "Multiplies the input value by 2",
      schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(2)})

    def run(%{value: value, amount: amount}, _context) do
      {:ok, %{value: value * amount}}
    end
  end

  defmodule ContextAwareMultiply do
    @moduledoc false
    use Action, name: "context_aware_multiply"

    def run(%{value: value}, %{multiplier: multiplier}), do: {:ok, %{value: value * multiplier}}
  end

  defmodule Subtract do
    @moduledoc false
    use Action,
      name: "subtract",
      description: "Subtracts second value from first value",
      schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(1)})

    def run(%{value: value, amount: amount}, _context) do
      {:ok, %{value: value - amount}}
    end
  end

  defmodule Divide do
    @moduledoc false
    use Action,
      name: "divide",
      description: "Divides first value by second value",
      schema: Zoi.object(%{value: Zoi.float(), amount: Zoi.float() |> Zoi.default(2.0)})

    def run(%{value: value, amount: amount}, _context) when amount != 0 do
      {:ok, %{value: value / amount}}
    end

    def run(_, _context) do
      raise "Cannot divide by zero"
    end
  end

  defmodule Square do
    @moduledoc false
    use Action,
      name: "square",
      description: "Squares the input value",
      schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context) do
      {:ok, %{value: value * value}}
    end
  end

  defmodule WriteFile do
    @moduledoc false
    use Action,
      name: "write_file",
      description: "Writes a file to the filesystem",
      schema: Zoi.object(%{file_name: Zoi.string(), content: Zoi.string()})

    def run(%{file_name: file_name, content: _content} = params, _context) do
      # Simulate file writing
      {:ok, Map.put(params, :written_file, file_name)}
    end
  end

  defmodule SchemaAction do
    @moduledoc false
    use Action,
      name: "schema_action",
      description: "A action with a complex schema and custom validation",
      schema:
        Zoi.object(%{
          string: Zoi.string() |> Zoi.optional(),
          integer: Zoi.integer() |> Zoi.optional(),
          atom: Zoi.atom() |> Zoi.optional(),
          boolean: Zoi.boolean() |> Zoi.optional(),
          list: Zoi.list(Zoi.string()) |> Zoi.optional(),
          keyword_list: Zoi.keyword(Zoi.any()) |> Zoi.optional(),
          map: Zoi.map() |> Zoi.optional(),
          custom:
            Zoi.string()
            |> Zoi.refine(fn value ->
              case __MODULE__.validate_custom(value) do
                {:ok, _atom} -> :ok
                {:error, reason} -> {:error, reason}
              end
            end)
            |> Zoi.optional()
        })

    # WARNING: This uses String.to_atom which is UNSAFE in production!
    # This creates new atoms from user input, which can lead to atom table exhaustion DoS.
    # Only for testing custom validation functions - DO NOT use this pattern in real actions.
    # In production, use String.to_existing_atom/1 or keep keys as strings.
    @spec validate_custom(any()) :: {:error, <<_::128>>} | {:ok, atom()}
    def validate_custom(value) when is_binary(value), do: {:ok, String.to_atom(value)}
    def validate_custom(_), do: {:error, "must be a string"}

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule DelayAction do
    @moduledoc false
    use Action,
      name: "delay_action",
      description: "Simulates a delay in action",
      schema:
        Zoi.object(%{
          delay: Zoi.integer(description: "Delay in milliseconds") |> Zoi.default(1000)
        })

    def run(%{delay: delay}, _context) do
      Process.sleep(delay)
      {:ok, %{result: "Async action completed"}}
    end
  end

  defmodule ContextAction do
    @moduledoc false
    use Action,
      name: "context_aware_action",
      description: "Uses context in its action",
      schema: Zoi.object(%{input: Zoi.string()})

    def run(%{input: input}, context) do
      {:ok, %{result: "#{input} processed with context: #{inspect(context)}"}}
    end
  end

  defmodule ResultAction do
    @moduledoc false
    use Action,
      name: "result_action",
      description: "Returns configurable result types",
      schema: Zoi.object(%{result_type: Zoi.enum([:success, :failure, :raw])})

    def run(%{result_type: :success}, _context) do
      {:ok, %{result: "success"}}
    end

    def run(%{result_type: :failure}, _context) do
      {:error, Error.internal_error("Simulated failure")}
    end

    def run(%{result_type: :raw}, _context) do
      %{result: "raw_result"}
    end
  end

  defmodule RetryAction do
    @moduledoc """
    Simulates an action with configurable retry behavior.
    """
    use Action,
      name: "retry_action",
      description: "Simulates an action with configurable retry behavior",
      schema:
        Zoi.object(%{
          max_attempts: Zoi.integer() |> Zoi.default(3),
          failure_type: Zoi.enum([:error, :exception]) |> Zoi.default(:error)
        })

    @spec run(map(), map()) :: {:ok, map()} | {:error, any()}
    def run(%{max_attempts: max_attempts, failure_type: failure_type}, context) do
      attempts_table = context.attempts_table

      # Get the current attempt count
      attempts =
        :ets.update_counter(attempts_table, :attempts, {2, 1, max_attempts, max_attempts})

      if attempts < max_attempts do
        # Simulate failure based on the failure_type
        case failure_type do
          :error -> {:error, Error.execution_error("Retry needed")}
          :exception -> raise "Retry exception"
        end
      else
        # Success on the last attempt
        {:ok, %{result: "success after #{attempts} attempts"}}
      end
    end
  end

  defmodule LongRunningAction do
    @moduledoc false
    use Action, name: "long_running_action"

    def run(_params, _context) do
      Enum.each(1..10, fn _ ->
        Process.sleep(10)
        if :persistent_term.get({__MODULE__, :cancel}, false), do: throw(:cancelled)
      end)

      {:ok, "Exec completed"}
    catch
      :throw, :cancelled -> {:error, "Exec cancelled"}
    after
      :persistent_term.erase({__MODULE__, :cancel})
    end
  end

  defmodule RateLimitedAction do
    @moduledoc false
    use Action,
      name: "rate_limited_action",
      description: "Demonstrates rate limiting functionality",
      schema: Zoi.object(%{action: Zoi.string()})

    @max_requests 5
    # 1 minute in milliseconds
    @time_window 60_000

    def run(%{action: action}, _context) do
      case check_rate_limit() do
        :ok ->
          {:ok, %{result: "Exec '#{action}' executed successfully"}}

        :error ->
          {:error, "Rate limit exceeded. Please try again later."}
      end
    end

    defp check_rate_limit do
      current_time = System.system_time(:millisecond)
      requests = :persistent_term.get({__MODULE__, :requests}, [])

      requests =
        Enum.filter(requests, fn timestamp -> current_time - timestamp < @time_window end)

      if length(requests) < @max_requests do
        :persistent_term.put({__MODULE__, :requests}, [current_time | requests])
        :ok
      else
        :error
      end
    end
  end

  defmodule StreamingAction do
    @moduledoc false
    use Action,
      name: "streaming_action",
      description: "Showcases streaming or chunked data processing",
      schema:
        Zoi.object(%{
          chunk_size: Zoi.integer() |> Zoi.default(10),
          total_items: Zoi.integer() |> Zoi.default(100)
        })

    def run(%{chunk_size: chunk_size, total_items: total_items}, _context) do
      stream =
        1
        |> Stream.iterate(&(&1 + 1))
        |> Stream.take(total_items)
        |> Stream.chunk_every(chunk_size)
        |> Stream.map(fn chunk ->
          # Simulate processing time
          Process.sleep(10)
          Enum.sum(chunk)
        end)

      {:ok, %{stream: stream}}
    end
  end

  defmodule ConcurrentAction do
    @moduledoc false
    use Action,
      name: "concurrent_action",
      description: "Showcases concurrent processing of multiple inputs",
      schema: Zoi.object(%{inputs: Zoi.list(Zoi.integer())})

    def run(%{inputs: inputs}, _context) do
      results =
        inputs
        |> Task.async_stream(
          fn input ->
            # Simulate varying processing times
            Process.sleep(:rand.uniform(100))
            input * 2
          end,
          timeout: 5000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      {:ok, %{results: results}}
    end
  end

  defmodule IOAction do
    @moduledoc """
    Test action module that demonstrates various IO operations.

    Used for testing IO-related functionality within actions.
    """

    use Action,
      name: "io_action",
      description: "Showcases various IO operations",
      schema:
        Zoi.object(%{
          input: Zoi.any() |> Zoi.default(%{foo: "bar"}),
          operation: Zoi.enum([:puts, :inspect, :write])
        })

    @impl true
    def run(%{input: _input, operation: :inspect} = params, _context) do
      # credo:disable-for-next-line Credo.Check.Warning.IoInspect
      IO.inspect(params, label: "IOAction")
      {:ok, params}
    end

    @impl true
    def run(%{input: input, operation: :puts}, _context) do
      IO.puts(input)
      {:ok, %{input: input}}
    end

    @impl true
    def run(%{input: input, operation: :write}, _context) do
      IO.write(input)
      {:ok, %{input: input}}
    end
  end

  defmodule FormatUser do
    @moduledoc false
    use Action,
      name: "format_user",
      description: "Formats user data",
      schema:
        Zoi.object(%{
          name: Zoi.string(description: "User's full name"),
          email: Zoi.string(description: "User's email address"),
          age: Zoi.integer(description: "User's age")
        })

    def run(params, _context) do
      %{name: name, email: email, age: age} = params

      {:ok,
       %{
         formatted_name: String.trim(name),
         email: String.downcase(email),
         age: age,
         is_adult: age >= 18
       }}
    end
  end

  defmodule EnrichUserData do
    @moduledoc false
    use Action,
      name: "enrich_user_data",
      description: "Adds additional user information",
      schema: Zoi.object(%{formatted_name: Zoi.string(), email: Zoi.string()})

    def run(%{formatted_name: name, email: email}, _context) do
      {:ok,
       %{
         username: generate_username(name),
         avatar_url: get_gravatar_url(email)
       }}
    end

    defp generate_username(name) do
      name
      |> String.downcase()
      |> String.replace(" ", ".")
    end

    defp get_gravatar_url(email) do
      hash = :crypto.hash(:md5, email) |> Base.encode16(case: :lower)
      "https://www.gravatar.com/avatar/#{hash}"
    end
  end

  defmodule NotifyUser do
    @moduledoc false
    use Action,
      name: "notify_user",
      description: "Sends welcome notification to user",
      schema: Zoi.object(%{email: Zoi.string(), username: Zoi.string()})

    def run(%{email: email, username: username}, _context) do
      # In a real app, you'd send an actual email
      {:ok,
       %{
         notification_sent: true,
         notification_type: "welcome_email",
         recipient: %{
           email: email,
           username: username
         }
       }}
    end
  end

  defmodule StateCheckAction do
    @moduledoc false
    use Action,
      name: "state_check_action",
      description: "Verifies state is injected into context"

    def run(_params, context) do
      {:ok, %{state_in_context: context.state}}
    end
  end

  defmodule Echo do
    @moduledoc false

    @doc """
    Simple echo action that returns its input parameters.
    """
    def run(params, _context, _opts) do
      {:ok, params}
    end
  end

  defmodule MetadataAction do
    @moduledoc false
    use Action,
      name: "metadata_action",
      description: "Demonstrates action metadata",
      schema: Zoi.object(%{})

    def run(_params, context) do
      {:ok, %{context: context}}
    end
  end
end
