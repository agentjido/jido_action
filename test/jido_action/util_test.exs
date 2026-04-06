defmodule JidoTest.Action.UtilTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Action.Util

  @moduletag :capture_log

  defp put_log_level_config(value) do
    original = Application.get_env(:jido_action, :default_log_level)

    if is_nil(value) do
      Application.delete_env(:jido_action, :default_log_level)
    else
      Application.put_env(:jido_action, :default_log_level, value)
    end

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:jido_action, :default_log_level)
      else
        Application.put_env(:jido_action, :default_log_level, original)
      end
    end)
  end

  describe "cond_log/4" do
    test "logs when threshold level equals message level" do
      assert :ok = Util.cond_log(:info, :info, "test message")
    end

    test "logs when threshold level is less than message level" do
      assert :ok = Util.cond_log(:debug, :info, "test message")
    end

    test "does not log when threshold level is greater than message level" do
      assert :ok = Util.cond_log(:info, :debug, "test message")
    end

    test "does not log when threshold level is invalid" do
      assert :ok = Util.cond_log(:invalid_level, :info, "test message")
    end

    test "does not log when message level is invalid" do
      assert :ok = Util.cond_log(:info, :invalid_level, "test message")
    end

    test "does not log when both levels are invalid" do
      assert :ok = Util.cond_log(:invalid_threshold, :invalid_message, "test message")
    end

    test "accepts additional logger options" do
      assert :ok = Util.cond_log(:debug, :info, "test message", metadata: %{test: true})
    end

    test "works with all valid log levels" do
      valid_levels = [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug]

      for threshold <- valid_levels, message <- valid_levels do
        assert :ok = Util.cond_log(threshold, message, "test")
      end
    end
  end

  describe "default_log_level/0" do
    test "falls back to :info when app config is missing" do
      put_log_level_config(nil)
      assert Util.default_log_level() == :info
    end

    test "returns configured level when valid" do
      put_log_level_config(:debug)
      assert Util.default_log_level() == :debug
    end

    test "warns and falls back when config is invalid" do
      put_log_level_config(:loud)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Util.default_log_level() == :info
        end)

      assert log =~ "Invalid :jido_action config for :default_log_level"
      assert log =~ ":loud"
    end
  end

  describe "resolve_log_level/1" do
    test "uses per-call override when valid" do
      put_log_level_config(:info)
      assert Util.resolve_log_level(log_level: :debug) == :debug
    end

    test "uses config default when no override is given" do
      put_log_level_config(:warning)
      assert Util.resolve_log_level([]) == :warning
    end

    test "warns and falls back to config default when override is invalid" do
      put_log_level_config(:warning)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Util.resolve_log_level(log_level: :verbose) == :warning
        end)

      assert log =~ "Invalid execution :log_level option"
      assert log =~ ":verbose"
    end
  end

  describe "validate_name/1" do
    test "validates names that start with a letter" do
      assert :ok = Util.validate_name("valid_name")
      assert :ok = Util.validate_name("ValidName")
      assert :ok = Util.validate_name("a")
      assert :ok = Util.validate_name("A")
    end

    test "validates names with letters, numbers, and underscores" do
      assert :ok = Util.validate_name("valid_name_123")
      assert :ok = Util.validate_name("TestAction42")

      assert :ok = Util.validate_name("action_name_with_underscores")
    end

    test "rejects names that start with numbers" do
      assert {:error,
              "The name must start with a letter and contain only letters, numbers, and underscores."} =
               Util.validate_name("123invalid")
    end

    test "rejects names that start with underscores" do
      assert {:error,
              "The name must start with a letter and contain only letters, numbers, and underscores."} =
               Util.validate_name("_invalid")
    end

    test "rejects names with hyphens" do
      assert {:error,
              "The name must start with a letter and contain only letters, numbers, and underscores."} =
               Util.validate_name("invalid-name")
    end

    test "rejects names with spaces" do
      assert {:error,
              "The name must start with a letter and contain only letters, numbers, and underscores."} =
               Util.validate_name("invalid name")
    end

    test "rejects names with special characters" do
      assert {:error,
              "The name must start with a letter and contain only letters, numbers, and underscores."} =
               Util.validate_name("invalid@name")
    end

    test "rejects empty strings" do
      assert {:error,
              "The name must start with a letter and contain only letters, numbers, and underscores."} =
               Util.validate_name("")
    end

    test "rejects non-binary inputs" do
      assert {:error, "Invalid name format."} = Util.validate_name(nil)
      assert {:error, "Invalid name format."} = Util.validate_name(123)
      assert {:error, "Invalid name format."} = Util.validate_name(:atom)
      assert {:error, "Invalid name format."} = Util.validate_name(%{})
      assert {:error, "Invalid name format."} = Util.validate_name([])
    end
  end

  describe "normalize_result/1" do
    test "normalizes nested ok tuples" do
      assert {:ok, "value"} = Util.normalize_result({:ok, {:ok, "value"}})
    end

    test "normalizes nested ok-error tuples" do
      assert {:error, "reason"} = Util.normalize_result({:ok, {:error, "reason"}})
    end

    test "handles invalid nested error-ok tuples" do
      assert {:error, "Invalid nested error tuple"} =
               Util.normalize_result({:error, {:ok, "value"}})
    end

    test "normalizes nested error tuples" do
      assert {:error, "reason"} = Util.normalize_result({:error, {:error, "reason"}})
    end

    test "passes through simple ok tuples" do
      assert {:ok, "value"} = Util.normalize_result({:ok, "value"})
    end

    test "passes through simple error tuples" do
      assert {:error, "reason"} = Util.normalize_result({:error, "reason"})
    end

    test "wraps plain values in ok tuples" do
      assert {:ok, "value"} = Util.normalize_result("value")
      assert {:ok, 42} = Util.normalize_result(42)
      assert {:ok, %{key: "value"}} = Util.normalize_result(%{key: "value"})
      assert {:ok, [1, 2, 3]} = Util.normalize_result([1, 2, 3])
      assert {:ok, nil} = Util.normalize_result(nil)
    end
  end

  describe "wrap_ok/1" do
    test "passes through ok tuples unchanged" do
      assert {:ok, "value"} = Util.wrap_ok({:ok, "value"})
      assert {:ok, 42} = Util.wrap_ok({:ok, 42})
      assert {:ok, nil} = Util.wrap_ok({:ok, nil})
    end

    test "passes through error tuples unchanged" do
      assert {:error, "reason"} = Util.wrap_ok({:error, "reason"})
      assert {:error, :timeout} = Util.wrap_ok({:error, :timeout})
    end

    test "wraps plain values in ok tuples" do
      assert {:ok, "value"} = Util.wrap_ok("value")
      assert {:ok, 42} = Util.wrap_ok(42)
      assert {:ok, %{key: "value"}} = Util.wrap_ok(%{key: "value"})
      assert {:ok, [1, 2, 3]} = Util.wrap_ok([1, 2, 3])
      assert {:ok, nil} = Util.wrap_ok(nil)
      assert {:ok, :atom} = Util.wrap_ok(:atom)
    end
  end

  describe "wrap_error/1" do
    test "passes through error tuples unchanged" do
      assert {:error, "reason"} = Util.wrap_error({:error, "reason"})
      assert {:error, :timeout} = Util.wrap_error({:error, :timeout})
      assert {:error, %{type: :validation}} = Util.wrap_error({:error, %{type: :validation}})
    end

    test "wraps plain values in error tuples" do
      assert {:error, "reason"} = Util.wrap_error("reason")
      assert {:error, :timeout} = Util.wrap_error(:timeout)
      assert {:error, %{type: :validation}} = Util.wrap_error(%{type: :validation})
      assert {:error, 500} = Util.wrap_error(500)
      assert {:error, nil} = Util.wrap_error(nil)
    end
  end
end
