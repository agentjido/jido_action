defmodule Jido.Action.SanitizerTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Sanitizer
  alias JidoTest.Support.RaisingInspectStruct

  defmodule NestedReason do
    defstruct [:message, :field, :meta, :nested]
  end

  test "transport profile recursively converts nested structs and tuples" do
    reason = %NestedReason{
      message: "bad input",
      field: :transport,
      meta: {:retry, 2},
      nested: %NestedReason{message: "nested", field: :inner, meta: {:ok, :done}}
    }

    sanitized = Sanitizer.sanitize(%{reason: reason, tuple: {:ok, reason}})

    assert sanitized.reason.__struct__ == inspect(NestedReason)
    assert sanitized.reason.field == :transport
    assert sanitized.reason.meta == [:retry, 2]
    assert sanitized.reason.nested.__struct__ == inspect(NestedReason)
    assert sanitized.reason.nested.meta == [:ok, :done]
    assert sanitized.tuple == [:ok, sanitized.reason]
    assert {:ok, _} = Jason.encode(sanitized)
  end

  test "transport profile preserves exception metadata and stringifies opaque leaves" do
    sanitized =
      Sanitizer.sanitize(%{
        error: %RuntimeError{message: "boom"},
        pid: self(),
        ref: make_ref(),
        fun: fn -> :ok end
      })

    assert sanitized.error.__struct__ == inspect(RuntimeError)
    assert sanitized.error.__exception__ == true
    assert sanitized.error.message == "boom"
    assert is_binary(sanitized.pid)
    assert is_binary(sanitized.ref)
    assert is_binary(sanitized.fun)
    assert {:ok, _} = Jason.encode(sanitized)
  end

  test "transport profile stringifies non-scalar keys and survives raising Inspect structs" do
    key = %RaisingInspectStruct{value: 1}
    sanitized = Sanitizer.sanitize(%{key => %{nested: %RaisingInspectStruct{value: 2}}})
    [sanitized_key] = Map.keys(sanitized)

    assert is_binary(sanitized_key)
    assert sanitized_key =~ "RaisingInspectStruct"
    assert sanitized[sanitized_key].nested.__struct__ == inspect(RaisingInspectStruct)
    assert sanitized[sanitized_key].nested.value == 2
    assert {:ok, _} = Jason.encode(sanitized)
  end

  test "transport profile handles improper lists without raising" do
    sanitized = Sanitizer.sanitize(%{improper: [1 | 2]})

    assert sanitized.improper == %{
             __type__: :improper_list,
             items: [1],
             tail: 2
           }

    assert {:ok, _} = Jason.encode(sanitized)
  end

  test "telemetry profile preserves redaction, truncation, and tuple semantics" do
    payload = %{
      password: "secret",
      list: Enum.to_list(1..30),
      tuple: {:ok, %{token: "inner-secret"}},
      nested: %{l1: %{l2: %{l3: %{l4: %{token: "too-deep"}}}}}
    }

    sanitized = Sanitizer.sanitize_telemetry(payload)

    assert sanitized.password == "[REDACTED]"
    assert length(sanitized.list) == 26
    assert List.last(sanitized.list) == %{__truncated_items__: 5}
    assert sanitized.tuple == {:ok, %{token: "[REDACTED]"}}

    assert get_in(sanitized, [:nested, :l1, :l2, :l3]) == %{
             __truncated_depth__: 4,
             type: :map,
             size: 1
           }
  end

  test "telemetry profile handles improper lists without raising" do
    sanitized =
      Sanitizer.sanitize_telemetry(%{improper: [%{token: "secret"} | %{password: "hidden"}]})

    assert sanitized.improper == %{
             __type__: :improper_list,
             items: [%{token: "[REDACTED]"}],
             tail: %{password: "[REDACTED]"}
           }
  end
end
