defmodule Jido.Action.ErrorTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error
  alias Jido.Action.Error.Internal.UnknownError

  defmodule Reason do
    defstruct [:message, :field, :meta]
  end

  describe "error creation functions" do
    test "validation_error/2 creates InvalidInputError with details" do
      error = Error.validation_error("must be positive", field: :count, value: -1)

      assert %Error.InvalidInputError{} = error
      assert error.message == "must be positive"
      assert error.field == :count
      assert error.value == -1
      assert error.details[:field] == :count
      assert error.details[:value] == -1
    end

    test "validation_error/1 creates InvalidInputError with defaults" do
      error = Error.validation_error("invalid input")

      assert %Error.InvalidInputError{} = error
      assert error.message == "invalid input"
      assert error.field == nil
      assert error.value == nil
      assert error.details == %{}
    end

    test "execution_error/2 creates ExecutionFailureError" do
      error = Error.execution_error("failed to execute", step: :process)

      assert %Error.ExecutionFailureError{} = error
      assert error.message == "failed to execute"
      assert error.details[:step] == :process
    end

    test "execution_error/1 creates ExecutionFailureError with defaults" do
      error = Error.execution_error("execution failed")

      assert %Error.ExecutionFailureError{} = error
      assert error.message == "execution failed"
      assert error.details == %{}
    end

    test "config_error/2 creates ConfigurationError" do
      error = Error.config_error("missing required config", key: :database_url)

      assert %Error.ConfigurationError{} = error
      assert error.message == "missing required config"
      assert error.details[:key] == :database_url
    end

    test "config_error/1 creates ConfigurationError with defaults" do
      error = Error.config_error("configuration error")

      assert %Error.ConfigurationError{} = error
      assert error.message == "configuration error"
      assert error.details == %{}
    end

    test "timeout_error/2 creates TimeoutError with timeout value" do
      error = Error.timeout_error("operation timed out", timeout: 5000)

      assert %Error.TimeoutError{} = error
      assert error.message == "operation timed out"
      assert error.timeout == 5000
      assert error.details[:timeout] == 5000
    end

    test "timeout_error/1 creates TimeoutError with defaults" do
      error = Error.timeout_error("timeout occurred")

      assert %Error.TimeoutError{} = error
      assert error.message == "timeout occurred"
      assert error.timeout == nil
      assert error.details == %{}
    end

    test "internal_error/2 creates InternalError" do
      error = Error.internal_error("unexpected failure", component: :database)

      assert %Error.InternalError{} = error
      assert error.message == "unexpected failure"
      assert error.details[:component] == :database
    end

    test "internal_error/1 creates InternalError with defaults" do
      error = Error.internal_error("internal error")

      assert %Error.InternalError{} = error
      assert error.message == "internal error"
      assert error.details == %{}
    end
  end

  describe "exception creation" do
    test "InvalidInputError.exception/1 with all options" do
      error =
        Error.InvalidInputError.exception(
          message: "custom message",
          field: :email,
          value: "invalid@",
          details: %{extra: "info"}
        )

      assert %Error.InvalidInputError{} = error
      assert error.message == "custom message"
      assert error.field == :email
      assert error.value == "invalid@"
      assert error.details == %{extra: "info"}
    end

    test "InvalidInputError.exception/1 with defaults" do
      error = Error.InvalidInputError.exception([])

      assert %Error.InvalidInputError{} = error
      assert error.message == "Invalid input"
      assert error.field == nil
      assert error.value == nil
      assert error.details == %{}
    end

    test "ExecutionFailureError.exception/1 with all options" do
      error =
        Error.ExecutionFailureError.exception(
          message: "execution failed",
          details: %{step: "validation"}
        )

      assert %Error.ExecutionFailureError{} = error
      assert error.message == "execution failed"
      assert error.details == %{step: "validation"}
    end

    test "ExecutionFailureError.exception/1 with defaults" do
      error = Error.ExecutionFailureError.exception([])

      assert %Error.ExecutionFailureError{} = error
      assert error.message == "Execution failed"
      assert error.details == %{}
    end

    test "TimeoutError.exception/1 with all options" do
      error =
        Error.TimeoutError.exception(
          message: "timed out",
          timeout: 1000,
          details: %{operation: "network"}
        )

      assert %Error.TimeoutError{} = error
      assert error.message == "timed out"
      assert error.timeout == 1000
      assert error.details == %{operation: "network"}
    end

    test "TimeoutError.exception/1 with defaults" do
      error = Error.TimeoutError.exception([])

      assert %Error.TimeoutError{} = error
      assert error.message == "Action timed out"
      assert error.timeout == nil
      assert error.details == %{}
    end

    test "ConfigurationError.exception/1 with all options" do
      error =
        Error.ConfigurationError.exception(
          message: "config missing",
          details: %{key: :api_url}
        )

      assert %Error.ConfigurationError{} = error
      assert error.message == "config missing"
      assert error.details == %{key: :api_url}
    end

    test "ConfigurationError.exception/1 with defaults" do
      error = Error.ConfigurationError.exception([])

      assert %Error.ConfigurationError{} = error
      assert error.message == "Configuration error"
      assert error.details == %{}
    end

    test "InternalError.exception/1 with all options" do
      error =
        Error.InternalError.exception(
          message: "system failure",
          details: %{subsystem: "cache"}
        )

      assert %Error.InternalError{} = error
      assert error.message == "system failure"
      assert error.details == %{subsystem: "cache"}
    end

    test "InternalError.exception/1 with defaults" do
      error = Error.InternalError.exception([])

      assert %Error.InternalError{} = error
      assert error.message == "Internal error"
      assert error.details == %{}
    end

    test "Internal.UnknownError.exception/1 with all options" do
      error =
        UnknownError.exception(
          message: "unknown error",
          details: %{context: "test"}
        )

      assert %UnknownError{} = error
      assert error.message == "unknown error"
      assert error.details == %{context: "test"}
    end

    test "Internal.UnknownError.exception/1 with defaults" do
      error = UnknownError.exception([])

      assert %UnknownError{} = error
      assert error.message == "Unknown error"
      assert error.details == %{}
    end
  end

  describe "NimbleOptions formatting" do
    test "format_nimble_config_error/3 with empty keys_path" do
      error = %NimbleOptions.ValidationError{
        keys_path: [],
        message: "required :name option not found"
      }

      result = Error.format_nimble_config_error(error, "Action", MyModule)

      expected =
        "Invalid configuration given to use Jido.Action (Elixir.MyModule): required :name option not found"

      assert result == expected
    end

    test "format_nimble_config_error/3 with keys_path" do
      error = %NimbleOptions.ValidationError{
        keys_path: [:schema, :name],
        message: "must be a string"
      }

      result = Error.format_nimble_config_error(error, "Action", MyModule)

      expected =
        "Invalid configuration given to use Jido.Action (Elixir.MyModule) for key [:schema, :name]: must be a string"

      assert result == expected
    end

    test "format_nimble_config_error/3 with binary error" do
      result = Error.format_nimble_config_error("simple error", "Action", MyModule)
      assert result == "simple error"
    end

    test "format_nimble_config_error/3 with other error type" do
      result = Error.format_nimble_config_error({:error, :reason}, "Action", MyModule)
      assert result == "{:error, :reason}"
    end

    test "format_nimble_validation_error/3 with empty keys_path" do
      error = %NimbleOptions.ValidationError{
        keys_path: [],
        message: "required :count option not found"
      }

      result = Error.format_nimble_validation_error(error, "Action", MyAction)

      expected =
        "Invalid parameters for Action (Elixir.MyAction): required :count option not found"

      assert result == expected
    end

    test "format_nimble_validation_error/3 with keys_path" do
      error = %NimbleOptions.ValidationError{
        keys_path: [:user, :email],
        message: "must be a valid email"
      }

      result = Error.format_nimble_validation_error(error, "Action", MyAction)

      expected =
        "Invalid parameters for Action (Elixir.MyAction) at [:user, :email]: must be a valid email"

      assert result == expected
    end

    test "format_nimble_validation_error/3 with binary error" do
      result = Error.format_nimble_validation_error("validation failed", "Action", MyAction)
      assert result == "validation failed"
    end

    test "format_nimble_validation_error/3 with other error type" do
      result = Error.format_nimble_validation_error(%{error: "bad"}, "Action", MyAction)
      assert result == "%{error: \"bad\"}"
    end
  end

  describe "to_map/1" do
    test "normalizes invalid input errors to a plain map" do
      error = Error.validation_error("must be positive", field: :count, value: -1)

      assert %{
               type: :validation_error,
               message: "must be positive",
               details: %{field: :count, value: -1},
               retryable?: false
             } = Error.to_map(error)
    end

    test "normalizes timeout errors as retryable" do
      error = Error.timeout_error("tool timed out", timeout: 15_000)

      assert %{
               type: :timeout,
               message: "tool timed out",
               details: %{timeout: 15_000},
               retryable?: true
             } = Error.to_map(error)
    end

    test "preserves canonical map input while normalizing retryability" do
      error = %{type: :rate_limited, message: "try again later", details: %{provider: :openai}}

      assert %{
               type: :rate_limited,
               message: "try again later",
               details: %{provider: :openai},
               retryable?: true
             } = Error.to_map(error)
    end

    test "unwraps tagged error tuples" do
      assert %{type: :execution_error, message: "boom", retryable?: true} =
               Error.to_map({:error, Error.execution_error("boom"), []})
    end

    test "normalizes non-binary messages into strings" do
      assert %{type: :execution_error, message: "transient_error", retryable?: true} =
               Error.to_map(%{type: :execution_error, message: :transient_error, details: %{}})
    end

    test "normalizes raw atom reasons with conservative retry defaults" do
      assert %{type: :badarg, message: "badarg", retryable?: false} = Error.to_map(:badarg)
      assert %{type: :timeout, message: "timeout", retryable?: true} = Error.to_map(:timeout)
    end

    test "normalizes plain message maps without assuming structs" do
      error = %{
        message: "connection refused",
        code: 503,
        reason: %Reason{message: "nested", field: :transport, meta: {:retry, 1}}
      }

      mapped = Error.to_map(error)

      assert mapped.type == :execution_error
      assert mapped.message == "connection refused"
      assert mapped.details.code == 503
      assert mapped.details.reason.__struct__ == inspect(Reason)
      assert mapped.details.reason.field == :transport
      assert mapped.details.reason.meta == [:retry, 1]
      assert {:ok, _} = Jason.encode(mapped)
    end

    test "sanitizes structured execution details into Jason-safe maps" do
      error =
        Error.execution_error("boom", %{
          reason: %Reason{message: "nested", field: :transport, meta: {:retry, 2}},
          pair: {:error, %RuntimeError{message: "down"}}
        })

      mapped = Error.to_map(error)

      assert mapped.details.reason.__struct__ == inspect(Reason)
      assert mapped.details.reason.meta == [:retry, 2]

      assert mapped.details.pair == [
               :error,
               %{__exception__: true, __struct__: inspect(RuntimeError), message: "down"}
             ]

      assert {:ok, _} = Jason.encode(mapped)
    end
  end

  describe "Jason.Encoder for error structs" do
    test "InvalidInputError is directly JSON-encodable" do
      error = Error.validation_error("bad input", field: :name, value: 123)
      assert {:ok, json} = Jason.encode(error)
      decoded = Jason.decode!(json)
      assert decoded["message"] == "bad input"
      assert decoded["field"] == "name"
      # details excluded — may contain non-serializable terms
      refute Map.has_key?(decoded, "details")
    end

    test "ExecutionFailureError is directly JSON-encodable" do
      error = Error.execution_error("boom", %{stacktrace: [{Enum, :map, 2, []}]})
      assert {:ok, json} = Jason.encode(error)
      decoded = Jason.decode!(json)
      assert decoded["message"] == "boom"
      # details excluded — contains stacktrace tuples
      refute Map.has_key?(decoded, "details")
    end

    test "TimeoutError is directly JSON-encodable" do
      error = Error.timeout_error("timed out", timeout: 5000)
      assert {:ok, json} = Jason.encode(error)
      decoded = Jason.decode!(json)
      assert decoded["message"] == "timed out"
      assert decoded["timeout"] == 5000
    end

    test "ConfigurationError is directly JSON-encodable" do
      error = Error.config_error("missing key", %{key: :api_url})
      assert {:ok, json} = Jason.encode(error)
      decoded = Jason.decode!(json)
      assert decoded["message"] == "missing key"
    end

    test "InternalError is directly JSON-encodable" do
      error = Error.internal_error("unexpected", %{reason: :unknown})
      assert {:ok, json} = Jason.encode(error)
      decoded = Jason.decode!(json)
      assert decoded["message"] == "unexpected"
    end
  end

  describe "retryable?/1" do
    test "matches timeout and transient action errors" do
      assert Error.retryable?(Error.timeout_error("timed out", timeout: 500))
      assert Error.retryable?(%{type: :rate_limited, message: "slow down"})
      assert Error.retryable?(%{details: %{retry: true}})
      assert Error.retryable?(:transient_error)
    end

    test "rejects validation and configuration errors" do
      refute Error.retryable?(Error.validation_error("invalid"))
      refute Error.retryable?(Error.config_error("bad config"))
      refute Error.retryable?(%{details: %{retry: false}})
      refute Error.retryable?(:badarg)
    end
  end
end
