defmodule JidoTest.ExecAsyncTest do
  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureLog

  alias Jido.Exec
  alias JidoTest.TestActions.BasicAction
  alias JidoTest.TestActions.DelayAction
  alias JidoTest.TestActions.ErrorAction

  @moduletag :capture_log

  describe "run_async/4" do
    test "returns an async_ref with pid, ref, and owner" do
      capture_log(fn ->
        result = Exec.run_async(BasicAction, %{value: 5})
        assert is_map(result)
        assert is_pid(result.pid)
        assert is_reference(result.ref)
        assert result.owner == self()
      end)
    end
  end

  describe "await/2" do
    test "returns the result of a successful async action" do
      capture_log(fn ->
        async_ref = Exec.run_async(BasicAction, %{value: 5}, %{}, timeout: 50)
        assert {:ok, %{value: 5}} = Exec.await(async_ref)
      end)
    end

    test "returns an error for a failed async action" do
      capture_log(fn ->
        async_ref = Exec.run_async(ErrorAction, %{error_type: :runtime}, %{}, timeout: 50)

        assert {:error, error} = Exec.await(async_ref)
        assert is_exception(error)
        assert Exception.message(error) =~ "Runtime error"
      end)
    end

    test "returns a timeout error when the action exceeds the timeout" do
      capture_log(fn ->
        async_ref = Exec.run_async(DelayAction, %{delay: 200}, %{}, timeout: 75)

        assert {:error,
                %Jido.Action.Error.TimeoutError{message: "Async action timed out after 50ms"}} =
                 Exec.await(async_ref, 50)
      end)
    end

    test "returns a validation error for non-owner await attempts" do
      capture_log(fn ->
        caller = self()
        async_ref = Exec.run_async(DelayAction, %{delay: 50}, %{}, timeout: 500)

        spawn(fn ->
          send(caller, {:non_owner_await, Exec.await(async_ref, 500)})
        end)

        assert_receive {:non_owner_await,
                        {:error, %Jido.Action.Error.InvalidInputError{} = error}}

        assert Exception.message(error) =~ "Only the owner process can await this async action"
        assert {:ok, _result} = Exec.await(async_ref, 1_000)
      end)
    end
  end

  describe "cancel/1" do
    test "successfully cancels an async action" do
      capture_log(fn ->
        async_ref = Exec.run_async(BasicAction, %{value: 5})
        assert :ok = Exec.cancel(async_ref)

        refute Process.alive?(async_ref.pid)
      end)
    end

    test "returns ok when cancelling an already completed action" do
      capture_log(fn ->
        async_ref = Exec.run_async(BasicAction, %{value: 5})

        Exec.await(async_ref)
        assert :ok = Exec.cancel(async_ref)
      end)
    end

    test "accepts a pid directly" do
      capture_log(fn ->
        async_ref = Exec.run_async(BasicAction, %{value: 5})
        assert :ok = Exec.cancel(async_ref.pid)
        refute Process.alive?(async_ref.pid)
      end)
    end

    test "returns a validation error for non-owner cancel by async_ref" do
      capture_log(fn ->
        caller = self()
        async_ref = Exec.run_async(DelayAction, %{delay: 500}, %{}, timeout: 1_000)

        spawn(fn ->
          send(caller, {:non_owner_cancel_ref, Exec.cancel(async_ref)})
        end)

        assert_receive {:non_owner_cancel_ref,
                        {:error, %Jido.Action.Error.InvalidInputError{} = error}}

        assert Exception.message(error) =~ "Only the owner process can cancel this async action"
        assert Process.alive?(async_ref.pid)
        assert :ok = Exec.cancel(async_ref)
      end)
    end

    test "returns a validation error for non-owner cancel by pid" do
      capture_log(fn ->
        caller = self()
        async_ref = Exec.run_async(DelayAction, %{delay: 500}, %{}, timeout: 1_000)

        spawn(fn ->
          send(caller, {:non_owner_cancel_pid, Exec.cancel(async_ref.pid)})
        end)

        assert_receive {:non_owner_cancel_pid,
                        {:error, %Jido.Action.Error.InvalidInputError{} = error}}

        assert Exception.message(error) =~ "Only the owner process can cancel this async action"
        assert Process.alive?(async_ref.pid)
        assert :ok = Exec.cancel(async_ref.pid)
      end)
    end

    test "returns an error for invalid input" do
      assert {:error, %Jido.Action.Error.InvalidInputError{}} = Exec.cancel("invalid")
    end
  end

  test "owner can still cancel after a non-owner await attempt" do
    capture_log(fn ->
      test_pid = self()
      async_ref = Exec.run_async(DelayAction, %{delay: 2_000}, %{}, timeout: 2_000)

      spawn(fn ->
        result = Exec.await(async_ref, 100)
        send(test_pid, {:await_result, result})
      end)

      Process.sleep(50)
      assert :ok = Exec.cancel(async_ref)

      receive do
        {:await_result, result} ->
          assert {:error, %Jido.Action.Error.InvalidInputError{} = error} = result
          assert Exception.message(error) =~ "Only the owner process can await this async action"
      after
        2_000 ->
          flunk("Await did not complete in time")
      end

      refute Process.alive?(async_ref.pid)
    end)
  end
end
