defmodule Jido.Action.ErrorTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error
  alias Jido.Action.Error.Internal.UnknownError
  alias JidoTest.Support.RaisingInspectStruct

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

    test "constructors discard non-detail containers" do
      assert %Error.ExecutionFailureError{details: %{}} =
               Error.execution_error("execution failed", "not details")
    end

    test "constructors accept struct details" do
      validation_details = %Reason{field: :transport, meta: :request}
      timeout_details = URI.parse("https://example.com")

      assert %Error.InvalidInputError{field: :transport, details: ^validation_details} =
               Error.validation_error("invalid", validation_details)

      assert %Error.TimeoutError{timeout: nil, details: ^timeout_details} =
               Error.timeout_error("slow", timeout_details)
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

    test "Internal.UnknownError.message/1 normalizes opaque error values" do
      assert Exception.message(UnknownError.exception(error: :remote_failure)) == "remote_failure"

      assert Exception.message(UnknownError.exception(error: {:remote, 42})) ==
               "{:remote, 42}"
    end
  end

  describe "Splode compatibility" do
    test "to_error/1 preserves concrete action errors" do
      error = Error.execution_error("boom", step: :process)

      assert %Error.ExecutionFailureError{message: "boom", details: details} =
               Error.to_error(error)

      assert details == %{step: :process}
    end

    test "to_error/1 converts raw reasons without losing the message" do
      error = Error.to_error("external failure")

      assert %UnknownError{} = error

      assert Error.to_map(error) == %{
               type: :internal_error,
               message: "external failure",
               details: %{},
               retryable?: false
             }
    end

    test "to_class/1 aggregates concrete action errors by configured precedence" do
      error =
        Error.to_class([
          Error.execution_error("execution failed"),
          Error.validation_error("invalid input")
        ])

      assert %Error.Invalid{} = error
      assert error.class == :invalid

      assert error.errors |> Enum.map(& &1.__struct__) |> Enum.sort() == [
               Error.ExecutionFailureError,
               Error.InvalidInputError
             ]
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

    test "normalizes noncanonical map types into execution details" do
      error = %{type: :rate_limited, message: "try again later", details: %{provider: :openai}}

      assert %{
               type: :execution_error,
               message: "try again later",
               details: %{provider: :openai, kind: :rate_limited},
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
      assert %{
               type: :execution_error,
               message: "badarg",
               details: %{reason: :badarg},
               retryable?: false
             } =
               Error.to_map(:badarg)

      assert %{
               type: :execution_error,
               message: "timeout",
               details: %{reason: :timeout},
               retryable?: false
             } =
               Error.to_map(:timeout)
    end

    test "normalizes arbitrary non-atom reasons as non-retryable execution errors" do
      assert Error.to_map("plain failure") == %{
               type: :execution_error,
               message: "plain failure",
               details: %{},
               retryable?: false
             }
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
      assert is_binary(JSON.encode!(mapped))
    end

    test "sanitizes structured execution details into JSON-safe maps" do
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

      assert is_binary(JSON.encode!(mapped))
    end

    test "normalizes opaque execution details without exposing a sanitizer API" do
      error =
        Error.execution_error("boom", %{
          pid: self(),
          ref: make_ref(),
          fun: fn -> :ok end,
          improper: [1 | 2]
        })

      mapped = Error.to_map(error)

      assert is_binary(mapped.details.pid)
      assert is_binary(mapped.details.ref)
      assert is_binary(mapped.details.fun)

      assert mapped.details.improper == %{
               __type__: :improper_list,
               items: [1],
               tail: 2
             }

      assert is_binary(JSON.encode!(mapped))
    end

    test "unwraps two- and three-tuple error results" do
      assert %{type: :configuration_error, message: "bad config", retryable?: false} =
               Error.to_map({:error, Error.config_error("bad config")})

      assert %{type: :timeout, message: "too slow", retryable?: true} =
               Error.to_map({:error, Error.timeout_error("too slow"), %{directive: :retry}})
    end

    test "normalizes canonical alias types and code maps" do
      cases = [
        {%{type: :config_error, message: "bad config"}, :configuration_error, false},
        {%{type: :invalid_input, message: "bad input"}, :validation_error, false},
        {%{type: :invalid_input_error, message: "bad input"}, :validation_error, false},
        {%{type: :timeout_error, message: "slow"}, :timeout, true},
        {%{type: :execution_failure, message: "boom"}, :execution_error, true},
        {%{type: :execution_failure_error, message: "boom"}, :execution_error, true},
        {%{type: :internal, message: "oops"}, :internal_error, false},
        {%{code: :timeout_error, message: "slow"}, :timeout, true}
      ]

      for {input, type, retryable?} <- cases do
        assert %{type: ^type, retryable?: ^retryable?} = Error.to_map(input)
      end
    end

    test "honors explicit retryable flags while normalizing maps" do
      assert %{retryable?: false} =
               Error.to_map(%{
                 type: :execution_error,
                 message: "boom",
                 retryable?: false,
                 details: %{retry: true}
               })

      assert %{retryable?: true} =
               Error.to_map(%{
                 type: :validation_error,
                 message: "invalid",
                 retryable: true
               })
    end

    test "normalizes remaining concrete action errors" do
      assert %{
               type: :configuration_error,
               message: "missing",
               details: %{key: :url},
               retryable?: false
             } = Error.to_map(Error.config_error("missing", key: :url))

      assert %{
               type: :internal_error,
               message: "internal",
               details: %{retry: true},
               retryable?: false
             } = Error.to_map(Error.internal_error("internal", retry: true))

      assert %{
               type: :internal_error,
               message: "unknown",
               details: %{source: :splode},
               retryable?: false
             } =
               Error.to_map(
                 UnknownError.exception(message: "unknown", details: %{source: :splode})
               )
    end

    test "normalizes pseudo-struct action errors defensively" do
      cases = [
        {Error.InvalidInputError, :validation_error, "Invalid input", false},
        {Error.ExecutionFailureError, :execution_error, "Execution failed", true},
        {Error.TimeoutError, :timeout, "Action timed out", true},
        {Error.ConfigurationError, :configuration_error, "Configuration error", false},
        {Error.InternalError, :internal_error, "Internal error", false},
        {UnknownError, :internal_error, "Unknown error", false}
      ]

      for {module, type, message, retryable?} <- cases do
        malformed = %{
          __struct__: module,
          __exception__: true,
          details: %{nested: :detail},
          extra: "kept"
        }

        assert %{
                 type: ^type,
                 message: ^message,
                 details: %{nested: :detail, extra: "kept"},
                 retryable?: ^retryable?
               } = Error.to_map(malformed)
      end
    end

    test "normalizes pseudo-struct action errors with explicit messages" do
      malformed = %{
        __struct__: Error.TimeoutError,
        __exception__: true,
        message: "custom timeout",
        timeout: 250
      }

      assert %{
               type: :timeout,
               message: "custom timeout",
               details: %{timeout: 250},
               retryable?: true
             } = Error.to_map(malformed)
    end

    test "keeps pseudo-struct retry decisions consistent" do
      cases = [
        {Error.InvalidInputError, true},
        {Error.ConfigurationError, true},
        {Error.InternalError, true},
        {Error.TimeoutError, false}
      ]

      for {module, retry?} <- cases do
        malformed = %{
          __struct__: module,
          __exception__: true,
          details: %{retry: retry?}
        }

        assert Error.retryable?(malformed) == Error.to_map(malformed).retryable?
      end
    end

    test "normalizes keyword and invalid detail containers" do
      assert %{
               details: %{reason: :rate_limited, retry: false},
               retryable?: false
             } =
               Error.to_map(%{
                 type: :execution_error,
                 message: "rate limited",
                 details: [reason: :rate_limited, retry: false]
               })

      assert %{details: %{}} ==
               Error.to_map(%{
                 type: :execution_error,
                 message: "bad details",
                 details: [:not, :a, :keyword]
               })
               |> Map.take([:details])

      assert %{details: %{}} ==
               Error.to_map(%{type: :execution_error, message: "bad details", details: "nope"})
               |> Map.take([:details])
    end

    test "normalizes opaque detail keys while preserving scalar detail keys" do
      opaque_key = self()

      mapped =
        Error.to_map(%{
          type: :execution_error,
          message: "mixed detail keys",
          details: %{:atom_key => 1, "binary_key" => 2, 42 => 3, false => 4, opaque_key => :owner}
        })

      assert mapped.details[:atom_key] == 1
      assert mapped.details["binary_key"] == 2
      assert mapped.details[42] == 3
      assert mapped.details[false] == 4

      normalized_opaque_key = List.to_string(:erlang.pid_to_list(opaque_key))

      assert mapped.details[normalized_opaque_key] == :owner
    end

    test "extracts details from top-level message structs" do
      mapped =
        Error.to_map(%Reason{message: "struct failed", field: :transport, meta: {:retry, 1}})

      assert mapped.type == :execution_error
      assert mapped.message == "struct failed"
      assert mapped.details.field == :transport
      assert mapped.details.meta == [:retry, 1]
    end

    test "normalizes non-binary inspect-hostile messages" do
      mapped =
        Error.to_map(%{
          type: :execution_error,
          message: %RaisingInspectStruct{value: 1},
          details: %{values: [1, {:two, 2}, %{three: 3}]}
        })

      assert mapped.message =~ "RaisingInspectStruct"
      assert mapped.details.values == [1, [:two, 2], %{three: 3}]
      assert is_binary(JSON.encode!(mapped))
    end

    test "normalizes non-scalar detail keys and inspect-hostile structs" do
      key = %RaisingInspectStruct{value: 1}
      error = Error.execution_error("boom", %{key => %{nested: %RaisingInspectStruct{value: 2}}})

      mapped = Error.to_map(error)
      [normalized_key] = Map.keys(mapped.details)

      assert is_binary(normalized_key)
      assert normalized_key =~ "RaisingInspectStruct"
      assert mapped.details[normalized_key].nested.__struct__ == inspect(RaisingInspectStruct)
      assert mapped.details[normalized_key].nested.value == 2
      assert is_binary(JSON.encode!(mapped))
    end
  end

  describe "JSON encoding" do
    test "encodes InvalidInputError through normalized generic maps" do
      error = Error.validation_error("bad input", field: :name, value: 123)

      decoded = error |> JSON.encode!() |> JSON.decode!()

      assert decoded["type"] == "validation_error"
      assert decoded["message"] == "bad input"
      assert decoded["retryable?"] == false
      assert decoded["details"] == %{"field" => "name", "value" => 123}
    end

    test "encodes action error structs through normalized generic maps" do
      error =
        Error.execution_error("boom", %{
          reason: %Reason{message: "nested", field: :transport, meta: {:retry, 2}}
        })

      decoded = error |> JSON.encode!() |> JSON.decode!()

      assert decoded["type"] == "execution_error"
      assert decoded["message"] == "boom"
      assert decoded["retryable?"] == true
      assert decoded["details"]["reason"]["__struct__"] =~ "Reason"
      assert decoded["details"]["reason"]["meta"] == ["retry", 2]
    end

    test "encodes TimeoutError through normalized generic maps" do
      error = Error.timeout_error("timed out", timeout: 5000)

      decoded = error |> JSON.encode!() |> JSON.decode!()

      assert decoded["type"] == "timeout"
      assert decoded["message"] == "timed out"
      assert decoded["retryable?"] == true
      assert decoded["details"] == %{"timeout" => 5000}
    end

    test "encodes remaining concrete action errors through normalized generic maps" do
      errors = [
        {Error.config_error("bad config"), "configuration_error", false},
        {Error.internal_error("internal"), "internal_error", false},
        {UnknownError.exception(message: "unknown"), "internal_error", false}
      ]

      for {error, type, retryable?} <- errors do
        decoded = error |> JSON.encode!() |> JSON.decode!()

        assert decoded["type"] == type
        assert decoded["retryable?"] == retryable?
      end
    end

    test "encodes malformed execution failure maps without crashing" do
      malformed = %{
        __struct__: Error.ExecutionFailureError,
        __exception__: true,
        details: %{},
        tool_name: "list_directory"
      }

      decoded = malformed |> JSON.encode!() |> JSON.decode!()

      assert decoded == %{
               "type" => "execution_error",
               "message" => "Execution failed",
               "details" => %{"tool_name" => "list_directory"},
               "retryable?" => true
             }
    end

    test "encodes invalid UTF-8 messages, detail values, and detail keys" do
      error =
        Error.execution_error(<<255>>, %{
          <<253>> => <<252>>,
          payload: <<254>>
        })

      decoded = error |> JSON.encode!() |> JSON.decode!()

      assert decoded["message"] == "base64:/w=="
      assert decoded["details"]["payload"] == "base64:/g=="
      assert decoded["details"]["base64:/Q=="] == "base64:/A=="
    end

    test "encodes colliding detail keys without losing values" do
      error =
        Error.execution_error("key collisions", %{
          <<255>> => :invalid_binary,
          "base64:/w==" => :valid_binary,
          42 => :integer,
          "42" => :string_integer,
          :field => :atom,
          "field" => :string_atom
        })

      mapped = Error.to_map(error)
      assert map_size(mapped.details) == 6

      assert MapSet.new(Map.values(mapped.details)) ==
               MapSet.new([
                 :invalid_binary,
                 :valid_binary,
                 :integer,
                 :string_integer,
                 :atom,
                 :string_atom
               ])

      decoded = error |> JSON.encode!() |> JSON.decode!()
      assert map_size(decoded["details"]) == 6

      assert MapSet.new(Map.values(decoded["details"])) ==
               MapSet.new([
                 "invalid_binary",
                 "valid_binary",
                 "integer",
                 "string_integer",
                 "atom",
                 "string_atom"
               ])
    end
  end

  describe "retryable?/1" do
    test "matches timeout and explicitly retryable action errors" do
      assert Error.retryable?(Error.timeout_error("timed out", timeout: 500))
      assert Error.retryable?(%{type: :rate_limited, message: "slow down"})
      assert Error.retryable?(%{details: %{retry: true}})
      assert Error.retryable?(Error.execution_error("retry", retry: true))
      assert Error.retryable?({:error, Error.timeout_error("timed out")})
      assert Error.retryable?(%{retryable?: true})
      assert Error.retryable?(%{retryable: true})
      assert Error.retryable?(%{code: :timeout_error, details: %{}})
      assert Error.retryable?(%{details: [reason: %{retry: true}]})
    end

    test "rejects validation and configuration errors" do
      refute Error.retryable?(Error.validation_error("invalid"))
      refute Error.retryable?(Error.config_error("bad config"))
      refute Error.retryable?(Error.internal_error("internal"))
      refute Error.retryable?(Error.internal_error("internal", retry: true))
      refute Error.retryable?(UnknownError.exception(details: %{retry: false}))
      refute Error.retryable?({:error, Error.validation_error("invalid"), []})
      refute Error.retryable?(%{retryable?: false})
      refute Error.retryable?(%{retryable: false})
      refute Error.retryable?(%{type: :validation_error, details: %{}})
      refute Error.retryable?(%{type: :config_error, message: "bad config"})
      refute Error.retryable?(%{type: :invalid_input, message: "bad input"})
      refute Error.retryable?(%{type: :internal, message: "internal"})
      refute Error.to_map(Error.execution_error("badarg", %{reason: :badarg})).retryable?
      refute Error.to_map(Error.execution_error("badarg", %{"reason" => :badarg})).retryable?
      refute Error.retryable?(%{details: [reason: %{retry: false}]})
      refute Error.retryable?(%{details: %{retry: false}})
      refute Error.retryable?(%{details: %{"reason" => %{"retry" => false}}})
      refute Error.retryable?(%{details: :opaque})
      refute Error.retryable?("opaque failure")
      refute Error.retryable?(:transient_error)
      refute Error.retryable?(:badarg)
    end

    test "matches to_map retry decisions for raw reasons" do
      for reason <- ["opaque", 42, {:remote, :failure}, [:bad], %{}] do
        assert Error.retryable?(reason) == Error.to_map(reason).retryable?
      end
    end
  end
end
