defmodule JidoActionTest.ExternalErrorDataTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error, as: ActionError
  alias Jido.Exec.Error, as: ExecError
  alias Jido.Flow.Error, as: FlowError
  alias JidoActionTest.Support.RaisingInspectStruct
  alias JidoActionTest.Support.InspectProbe

  @families [ActionError, ExecError, FlowError]

  test "external conversion never calls a custom Inspect implementation" do
    probe = %InspectProbe{owner: self()}

    for family <- @families do
      details = %{probe => :struct_key, {probe, :key} => :tuple_key, improper: [probe | probe]}
      error = family.execution_error({:unsupported, probe}, details)
      assert is_binary(JSON.encode!(error))

      assert family.to_map(error).details["#Struct<JidoActionTest.Support.InspectProbe>"] ==
               :struct_key

      refute_received :unsafe_inspect_called
    end

    for {family, module} <- [
          {ActionError, ActionError.Internal.UnknownError},
          {FlowError, FlowError.Internal.UnknownError}
        ] do
      for reason <- [probe, {:nested, probe}] do
        error = module.exception(error: reason)
        assert is_binary(JSON.encode!(error))
        assert is_binary(family.to_map(error).message)
        refute_received :unsafe_inspect_called
        assert error.error === reason
      end
    end
  end

  test "malformed direct timeout details use the same fallback in each family" do
    for {family, module} <- [
          {ActionError, ActionError.TimeoutError},
          {ExecError, ExecError.AsyncTimeoutError},
          {FlowError, FlowError.TimeoutError}
        ] do
      for details <- [nil, self(), [entry: self()] ++ [:bad], [{:entry, self()} | :tail]] do
        error = module.exception(message: "late", timeout: 25, details: details)
        assert family.to_map(error).details == %{timeout: 25}
        assert is_binary(JSON.encode!(error))
        assert error.details === details
      end
    end
  end

  test "direct keyword details have the same item limit across error families" do
    for family <- @families do
      error = family.execution_error("failed")
      within_limit = %{error | details: List.duplicate({:entry, self()}, 64)}
      above_limit = %{error | details: List.duplicate({:entry, self()}, 65)}

      assert family.to_map(within_limit).details == %{entry: inspect(self())}
      assert family.to_map(above_limit).details == %{}
    end
  end

  test "list and tuple limits produce one marker when the term budget also expires" do
    branch = List.duplicate(List.duplicate(self(), 64), 64)
    items = [branch | Enum.to_list(1..64)]

    for family <- @families do
      list = family.to_map(family.execution_error("failed", items: items)).details.items

      tuple =
        family.to_map(family.execution_error("failed", items: List.to_tuple(items))).details.items

      assert tuple == list
      assert Enum.count(tuple, &(&1 == "#Truncated")) == 1
    end
  end

  test "Flow error groups convert each source value once within shared limits" do
    bytes = :binary.copy(<<255>>, 4_096)
    leaf = ActionError.execution_error(bytes, payload: bytes)
    group = %FlowError.Invalid{errors: [leaf]}
    mapped = FlowError.to_map(group)
    assert mapped.details.errors == [ActionError.to_map(leaf)]

    failure = %{node: "first", runnable_id: make_ref(), error: leaf}
    error = FlowError.flow_failure("probe", [failure])
    assert hd(FlowError.to_map(error).details.failures).error == ActionError.to_map(leaf)

    deep = Enum.reduce(1..100, leaf, fn _, child -> %FlowError.Invalid{errors: [child]} end)

    wide =
      Enum.reduce(1..5, leaf, fn _, child ->
        %FlowError.Invalid{errors: List.duplicate(child, 64)}
      end)

    for error <- [deep, wide] do
      encoded = JSON.encode!(error)
      assert encoded =~ "#Truncated"
      assert byte_size(encoded) < 6_000_000
    end

    for errors <- [[leaf | :tail], :invalid] do
      group = %FlowError.Invalid{errors: errors}
      encoded = JSON.encode!(group)
      refute encoded =~ "ExternalData.NestedError"
      assert group.errors === errors
    end

    for failures <- [[failure | :tail], [:invalid], :invalid] do
      error = %FlowError.ExecutionFailureError{failures: failures, details: nil}
      encoded = JSON.encode!(error)
      refute encoded =~ "ExternalData.NestedError"
      assert error.failures === failures
    end
  end

  test "all error families use the same conversion without changing rich details" do
    ref = make_ref()
    function = &__MODULE__.__info__/1
    exception = RuntimeError.exception("original failure")
    stacktrace = [{__MODULE__, :diagnostic, [self(), ref], [file: ~c"probe.ex", line: 42]}]
    identity = Runic.Identity.digest(:activation, :diagnostic)
    port = Port.open({:spawn_executable, :os.find_executable(~c"cat")}, [:binary])

    try do
      details = %{
        <<255>> => :binary_key,
        self() => :pid_key,
        ref => :reference_key,
        5 => :integer_key,
        1.5 => :float_key,
        nested: [%{tuple: {self(), ref, [nil, true, false, :atom, 12, 1.5]}}],
        empty_tuple: {},
        exception: exception,
        stacktrace: stacktrace,
        function: function,
        port: port,
        hostile: %RaisingInspectStruct{value: :untouched},
        improper: [1 | 2],
        payload: <<255>>,
        bits: <<1::1>>,
        identity: identity,
        retry: true
      }

      maps =
        for family <- @families do
          error = family.execution_error("failed", details)
          mapped = family.to_map(error)
          decoded = error |> JSON.encode!() |> JSON.decode!()

          assert error.details === details
          assert error.details.exception === exception
          assert error.details.stacktrace === stacktrace
          assert decoded == mapped |> JSON.encode!() |> JSON.decode!()

          assert mapped.details.nested == [
                   %{tuple: [inspect(self()), inspect(ref), [nil, true, false, :atom, 12, 1.5]]}
                 ]

          assert mapped.details.empty_tuple == []
          assert mapped.details.exception == "#Struct<RuntimeError>"
          assert mapped.details.hostile == "#Struct<JidoActionTest.Support.RaisingInspectStruct>"
          assert mapped.details.function == inspect(function)
          assert mapped.details.port == inspect(port)
          assert mapped.details.improper == "[1 | 2]"
          assert mapped.details.bits == "<<1::size(1)>>"
          assert mapped.details.identity == Runic.Identity.to_string(identity)
          assert mapped.details.payload == "base64:/w=="
          assert mapped.details["base64:/w=="] == :binary_key
          assert mapped.details[inspect(self())] == :pid_key
          assert mapped.details[inspect(ref)] == :reference_key
          assert mapped.details[5] == :integer_key
          assert mapped.details[1.5] == :float_key
          assert mapped.retryable? == (family != ExecError)
          mapped.details
        end

      assert Enum.uniq(maps) |> length() == 1
    after
      Port.close(port)
    end
  end

  test "all families bound depth, collection size, strings, and large integers" do
    deep = Enum.reduce(1..100, :leaf, fn _, acc -> [acc] end)
    large_map = Map.new(1..65, &{&1, self()})
    large_integer = Integer.pow(10, 100)

    details = %{
      deep: deep,
      list: Enum.to_list(1..65),
      tuple: List.to_tuple(Enum.to_list(1..65)),
      map: large_map,
      binary: String.duplicate("x", 4_097),
      valid_binary: String.duplicate("x", 4_096),
      integer: large_integer,
      valid_integer: large_integer - 1
    }

    for family <- @families do
      error = family.execution_error("failed", details)
      mapped = family.to_map(error)

      assert error.details === details
      assert mapped.details.deep == Enum.reduce(1..15, "#Truncated", fn _, acc -> [acc] end)
      assert mapped.details.list == Enum.to_list(1..64) ++ ["#Truncated"]
      assert mapped.details.tuple == mapped.details.list
      assert mapped.details.map == %{"__truncated__" => "map exceeds 64 entries"}
      assert mapped.details.binary == "#Truncated<binary>"
      assert mapped.details.valid_binary == details.valid_binary
      assert mapped.details.integer == "#Truncated<integer>"
      assert mapped.details.valid_integer == large_integer - 1
      assert is_binary(JSON.encode!(error))

      assert family.to_map(family.execution_error("failed", large_map)).details ==
               %{"__truncated__" => "map exceeds 64 entries"}
    end
  end

  test "the term budget bounds broad nested data and gives deterministic output" do
    branch = List.duplicate(List.duplicate(self(), 64), 64)
    details = %{b: branch, a: branch}
    reversed = Map.new(Enum.reverse(Enum.to_list(details)))

    for family <- @families do
      error = family.execution_error("failed", details)
      mapped = family.to_map(error)
      encoded = JSON.encode!(error)

      assert mapped == family.to_map(family.execution_error("failed", reversed))
      assert encoded == JSON.encode!(family.execution_error("failed", reversed))
      assert encoded =~ "#Truncated"
      assert byte_size(encoded) < 30_000
      assert error.details === details
    end
  end

  test "external conversion preserves a caught exception and its stacktrace" do
    {exception, stacktrace} =
      try do
        raise "original failure"
      rescue
        exception -> {exception, __STACKTRACE__}
      end

    for family <- @families do
      error = family.execution_error("failed", original: exception, stacktrace: stacktrace)
      assert is_binary(JSON.encode!(error))
      assert error.details.original === exception
      assert error.details.stacktrace === stacktrace
    end

    error = ActionError.execution_error("failed", original: exception)
    error = %{error | stacktrace: %Splode.Stacktrace{stacktrace: stacktrace}}
    assert is_binary(JSON.encode!(error))
    refute Map.has_key?(ActionError.to_map(error), :stacktrace)
    assert error.stacktrace.stacktrace === stacktrace
    assert error.details.original === exception
  end

  test "all families convert invalid messages and unsafe concrete detail fields" do
    for family <- @families do
      error = family.timeout_error(<<255>>, timeout: self())
      mapped = family.to_map(error)
      assert mapped.message == "base64:/w=="
      assert mapped.details.timeout == inspect(self())
      assert error.message == <<255>>
      assert error.details.timeout == self()
      assert is_binary(JSON.encode!(error))
    end

    error = ActionError.validation_error("invalid", field: self(), value: {make_ref(), self()})
    assert ActionError.to_map(error).details.field == inspect(self())
    assert is_binary(JSON.encode!(error))
  end
end
