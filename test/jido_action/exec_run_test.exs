defmodule JidoTest.ExecRunTest do
  use JidoTest.ActionCase, async: false
  use Mimic

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Jido.Action.Error
  alias Jido.Exec
  alias Jido.Exec.Validator
  alias JidoTest.TestActions.BasicAction
  alias JidoTest.TestActions.DelayAction
  alias JidoTest.TestActions.ErrorAction
  alias JidoTest.TestActions.IOAction
  alias JidoTest.TestActions.RetryAction

  @attempts_table :action_run_test_attempts

  @moduletag :capture_log

  setup :set_mimic_global

  setup do
    Logger.put_process_level(self(), :debug)

    :ets.new(@attempts_table, [:set, :public, :named_table])
    :ets.insert(@attempts_table, {:attempts, 0})

    on_exit(fn ->
      Logger.delete_process_level(self())

      if :ets.info(@attempts_table) != :undefined do
        :ets.delete(@attempts_table)
      end
    end)

    {:ok, attempts_table: @attempts_table}
  end

  describe "run/4" do
    test "executes action successfully" do
      stub(:telemetry, :execute, fn _, _, _ -> :ok end)

      log =
        capture_log(fn ->
          assert {:ok, %{value: 5}} = Exec.run(BasicAction, %{value: 5}, %{}, log_level: :debug)
        end)

      assert log =~ "Starting execution of JidoTest.TestActions.BasicAction"
      verify!()
    end

    # test "handles successful 3-item tuple with directive" do
    #   expect(System, :monotonic_time, fn :microsecond -> 0 end)
    #   expect(:telemetry, :execute, 2, fn _, _, _ -> :ok end)

    #   log =
    #     capture_log(fn ->
    #       assert {:ok, %{}, %Jido.Agent.Directive.Enqueue{}} =
    #                Exec.run(Jido.Actions.Directives.EnqueueAction, %{
    #                  action: BasicAction,
    #                  params: %{value: 5}
    #                })
    #     end)

    #   assert log =~
    #            "Executing Jido.Actions.Directives.EnqueueAction with params: %{params: %{value: 5}"

    #   verify!()
    # end

    # test "handles error 3-item tuple with directive" do
    #   expect(System, :monotonic_time, fn :microsecond -> 0 end)
    #   expect(:telemetry, :execute, 2, fn _, _, _ -> :ok end)

    #   log =
    #     capture_log(fn ->
    #       assert {:error, %Error{}, %Jido.Agent.Directive.Enqueue{}} =
    #                Exec.run(JidoTest.TestActions.ErrorDirective, %{
    #                  action: BasicAction,
    #                  params: %{value: 5}
    #                })
    #     end)

    #   assert log =~
    #            "Executing JidoTest.TestActions.ErrorDirective with params: %{params: %{value: 5}"

    #   assert log =~ "Action JidoTest.TestActions.ErrorDirective failed"
    #   verify!()
    # end

    test "handles action error" do
      stub(:telemetry, :execute, fn _, _, _ -> :ok end)

      log =
        capture_log(fn ->
          assert {:error, %_{} = error} =
                   Exec.run(ErrorAction, %{}, %{}, timeout: 50, log_level: :debug)

          assert is_exception(error)
        end)

      assert log =~ "Starting execution of JidoTest.TestActions.ErrorAction"
      assert log =~ "Action JidoTest.TestActions.ErrorAction failed"
      verify!()
    end

    test "retries on error and then succeeds", %{attempts_table: attempts_table} do
      stub(:telemetry, :execute, fn _, _, _ -> :ok end)

      capture_log(fn ->
        result =
          Exec.run(
            RetryAction,
            %{max_attempts: 3, failure_type: :error},
            %{attempts_table: attempts_table},
            max_retries: 2,
            backoff: 10,
            log_level: :debug
          )

        assert {:ok, %{result: "success after 3 attempts"}} = result
        assert :ets.lookup(attempts_table, :attempts) == [{:attempts, 3}]
      end)

      verify!()
    end

    test "fails after max retries", %{attempts_table: attempts_table} do
      stub(:telemetry, :execute, fn _, _, _ -> :ok end)

      capture_log(fn ->
        result =
          Exec.run(
            RetryAction,
            %{max_attempts: 5, failure_type: :error},
            %{attempts_table: attempts_table},
            max_retries: 2,
            backoff: 10,
            log_level: :debug
          )

        assert {:error, %_{} = error} = result
        assert is_exception(error)
        assert :ets.lookup(attempts_table, :attempts) == [{:attempts, 3}]
      end)

      verify!()
    end

    test "handles invalid params" do
      assert {:error, %_{} = error} = Exec.run(BasicAction, %{invalid: "params"})
      assert is_exception(error)
    end

    test "handles timeout" do
      capture_log(fn ->
        assert {:error, %_{} = error} =
                 Exec.run(DelayAction, %{delay: 1000}, %{}, timeout: 50)

        assert is_exception(error)
        message = Exception.message(error)

        assert message =~ "timed out after 50ms"
      end)
    end

    test "handles IO operations" do
      io =
        capture_io(fn ->
          assert {:ok, %{input: "test", operation: :inspect}} =
                   Exec.run(IOAction, %{input: "test", operation: :inspect}, %{}, timeout: 5000)
        end)

      assert io =~ "IOAction"
      assert io =~ "input"
      assert io =~ "test"
      assert io =~ "operation"
      assert io =~ "inspect"
    end

    test "passes metadata to the action context" do
      result =
        Exec.run(JidoTest.TestActions.MetadataAction, %{}, %{}, timeout: 1000, log_level: :debug)

      assert {:ok, %{metadata: metadata}} = result
      assert metadata[:name] == "metadata_action"
      assert metadata[:description] == "Demonstrates action metadata"
      assert metadata[:vsn] == "87.52.1"
      assert metadata[:schema] == []
    end
  end

  describe "normalize_params/1" do
    test "normalizes a map" do
      params = %{key: "value"}
      assert {:ok, ^params} = Exec.normalize_params(params)
    end

    test "normalizes a keyword list" do
      params = [key: "value"]
      assert {:ok, %{key: "value"}} = Exec.normalize_params(params)
    end

    test "normalizes {:ok, map}" do
      params = {:ok, %{key: "value"}}
      assert {:ok, %{key: "value"}} = Exec.normalize_params(params)
    end

    test "normalizes {:ok, keyword list}" do
      params = {:ok, [key: "value"]}
      assert {:ok, %{key: "value"}} = Exec.normalize_params(params)
    end

    test "handles {:error, reason}" do
      params = {:error, "some error"}

      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               Exec.normalize_params(params)
    end

    test "passes through exception errors" do
      errors = [
        Error.validation_error("validation failed"),
        Error.execution_error("execution failed"),
        Error.timeout_error("action timed out")
      ]

      for error <- errors do
        assert {:error, ^error} = Exec.normalize_params(error)
      end
    end

    test "returns error for invalid params" do
      params = "invalid"

      assert {:error, %Jido.Action.Error.InvalidInputError{message: "Invalid params type: " <> _}} =
               Exec.normalize_params(params)
    end
  end

  describe "normalize_context/1" do
    test "normalizes a map" do
      context = %{key: "value"}
      assert {:ok, ^context} = Exec.normalize_context(context)
    end

    test "normalizes a keyword list" do
      context = [key: "value"]
      assert {:ok, %{key: "value"}} = Exec.normalize_context(context)
    end

    test "returns error for invalid context" do
      context = "invalid"

      assert {:error,
              %Jido.Action.Error.InvalidInputError{message: "Invalid context type: " <> _}} =
               Exec.normalize_context(context)
    end
  end

  describe "validate_action/1" do
    defmodule NotAAction do
      @moduledoc false
      def validate_params(_), do: :ok
    end

    test "returns :ok for valid action" do
      assert :ok = Validator.validate_action(BasicAction)
    end

    test "returns error for action without run/2" do
      assert {:error,
              %Jido.Action.Error.InvalidInputError{
                message:
                  "Module JidoTest.ExecRunTest.NotAAction is not a valid action: missing run/2 function"
              }} = Validator.validate_action(NotAAction)
    end
  end

  describe "validate_params/2" do
    defmodule ValidatableAction do
      @moduledoc false

      def validate_params(%{value: value}) when is_integer(value), do: {:ok, %{value: value}}
      def validate_params(_params), do: {:error, Error.validation_error("invalid params")}

      def run(params, _context), do: {:ok, params}
    end

    test "returns validated params for valid params" do
      assert {:ok, %{value: 5}} = Validator.validate_params(ValidatableAction, %{value: 5})
    end

    test "returns error for invalid params" do
      {:error, %_{} = error} =
        Validator.validate_params(ValidatableAction, %{invalid: "params"})

      assert is_exception(error)
    end
  end

  describe "application configuration" do
    test "honors application config for timeout, max_retries, and backoff" do
      # Set custom application config
      original_timeout = Application.get_env(:jido_action, :default_timeout)
      original_max_retries = Application.get_env(:jido_action, :default_max_retries)
      original_backoff = Application.get_env(:jido_action, :default_backoff)

      try do
        Application.put_env(:jido_action, :default_timeout, 1_000)
        Application.put_env(:jido_action, :default_max_retries, 2)
        Application.put_env(:jido_action, :default_backoff, 50)

        # Test timeout from application config (using a very slow action to ensure timeout)
        # Disable retries for this test to isolate timeout behavior
        start_time = System.monotonic_time(:millisecond)

        assert {:error, %Jido.Action.Error.TimeoutError{}} =
                 Exec.run(DelayAction, %{delay: 2_000}, %{}, max_retries: 0)

        end_time = System.monotonic_time(:millisecond)
        duration = end_time - start_time

        # Should timeout around 1 second (our configured timeout), not the default 5 seconds
        assert duration >= 900 && duration <= 1_200,
               "Expected timeout around 1s, but took #{duration}ms"

        # Test max_retries from application config
        # Reset attempts counter
        :ets.insert(@attempts_table, {:attempts, 0})

        assert {:ok, %{result: result}} =
                 Exec.run(
                   RetryAction,
                   %{should_succeed: false, max_attempts: 2},
                   %{attempts_table: @attempts_table},
                   []
                 )

        # Should succeed after exhausting retries
        assert result =~ "success after 2 attempts"

        # Should have attempted 2 times total (1 initial + 1 retry, then success on 2nd attempt)
        [{:attempts, attempts}] = :ets.lookup(@attempts_table, :attempts)
        assert attempts == 2
      after
        # Restore original config
        if original_timeout do
          Application.put_env(:jido_action, :default_timeout, original_timeout)
        else
          Application.delete_env(:jido_action, :default_timeout)
        end

        if original_max_retries do
          Application.put_env(:jido_action, :default_max_retries, original_max_retries)
        else
          Application.delete_env(:jido_action, :default_max_retries)
        end

        if original_backoff do
          Application.put_env(:jido_action, :default_backoff, original_backoff)
        else
          Application.delete_env(:jido_action, :default_backoff)
        end
      end
    end

    test "uses configured default_log_level and allows per-call overrides" do
      original_log_level = Application.get_env(:jido_action, :default_log_level)

      try do
        Application.put_env(:jido_action, :default_log_level, :debug)

        configured_log =
          capture_log(fn ->
            assert {:ok, %{value: 5}} = Exec.run(BasicAction, %{value: 5}, %{})
          end)

        assert configured_log =~ "Starting execution of JidoTest.TestActions.BasicAction"

        overridden_log =
          capture_log(fn ->
            assert {:ok, %{value: 5}} =
                     Exec.run(BasicAction, %{value: 5}, %{}, log_level: :error)
          end)

        refute overridden_log =~ "Starting execution of JidoTest.TestActions.BasicAction"
      after
        if original_log_level do
          Application.put_env(:jido_action, :default_log_level, original_log_level)
        else
          Application.delete_env(:jido_action, :default_log_level)
        end
      end
    end

    test "accepts deprecated error_normalization config as a compatibility shim" do
      original_error_normalization = Application.get_env(:jido_action, :error_normalization)

      try do
        Application.put_env(:jido_action, :error_normalization, :granular)

        log =
          capture_log(fn ->
            assert {:ok, %{value: 5}} = Exec.run(BasicAction, %{value: 5}, %{})
          end)

        assert log =~
                 ":jido_action config :error_normalization=:granular is deprecated and ignored"
      after
        if is_nil(original_error_normalization) do
          Application.delete_env(:jido_action, :error_normalization)
        else
          Application.put_env(:jido_action, :error_normalization, original_error_normalization)
        end
      end
    end
  end
end
