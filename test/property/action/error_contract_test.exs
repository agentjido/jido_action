defmodule JidoActionTest.Property.Action.ErrorContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag :property
  alias Jido.Action.Error

  @tag contracts: ["ERROR-001"]
  @tag contract_cases: [
         "ERROR-001/constructor-types",
         "ERROR-001/retry-policy",
         "ERROR-001/error-wrappers",
         "ERROR-001/untrusted-map"
       ]
  property "canonical errors preserve details and only permitted error types can request retry" do
    check all(
            value <- integer(),
            message <- string(:alphanumeric, max_length: 20),
            max_runs: 40
          ) do
      for retry <- [false, true],
          {constructor, type, retry_allowed?} <- [
            {:validation_error, :validation_error, false},
            {:execution_error, :execution_error, true},
            {:timeout_error, :timeout, true},
            {:config_error, :configuration_error, false},
            {:internal_error, :internal_error, false}
          ] do
        details = %{
          value: value,
          field: :value,
          timeout: value,
          retry: retry,
          payload: %{value: value}
        }

        for form <- [details, Map.to_list(details)] do
          error = apply(Error, constructor, [message, form])

          expected = %{
            type: type,
            message: message,
            details: details,
            retryable?: retry and retry_allowed?
          }

          assert Error.to_map(error) == expected
          assert Error.to_map({:error, error}) == expected
          assert Error.to_map({:error, error, [:discard]}) == expected
          assert Error.retryable?(error) == expected.retryable?
        end
      end

      spoofed = %{type: :timeout, retry: true, payload: value}
      assert %{type: :execution_error, details: %{}, retryable?: false} = Error.to_map(spoofed)
      refute Error.retryable?(spoofed)
    end
  end
end
