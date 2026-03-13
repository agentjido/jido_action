defmodule JidoTest.Exec.TelemetrySanitizationTest do
  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureLog

  alias Jido.Exec.Telemetry
  alias JidoTest.Support.RaisingInspectStruct

  defmodule CredentialsStruct do
    defstruct [:api_key, :note, :nested]
  end

  defmodule CustomInspectStruct do
    defstruct [:entries, :name]
  end

  def handle_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp assert_struct_summary(summary, module, size) do
    assert summary == %{
             __truncated_depth__: 4,
             type: :struct,
             module: inspect(module),
             size: size
           }
  end

  setup do
    test_pid = self()
    handler_id = "jido-telemetry-sanitization-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:jido, :action, :start], [:jido, :action, :stop]],
        &__MODULE__.handle_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "emit_start_event redacts sensitive keys and caps payload size" do
    long_string = String.duplicate("x", 300)

    params = %{
      password: "super-secret",
      list: Enum.to_list(1..30),
      nested: %{layer1: %{layer2: %{layer3: %{layer4: %{token: "inner-secret"}}}}},
      data: %CredentialsStruct{
        api_key: "api-123",
        note: long_string,
        nested: %{client_secret: "nested-secret"}
      }
    }

    context = %{"authorization" => "Bearer top-secret", "note" => long_string}

    assert :ok = Telemetry.emit_start_event(__MODULE__, params, context)

    assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, metadata}

    assert metadata.params.password == "[REDACTED]"
    assert metadata.context["authorization"] == "[REDACTED]"
    assert String.contains?(metadata.context["note"], "...(truncated 44 bytes)")
    assert length(metadata.params.list) == 26
    assert List.last(metadata.params.list) == %{__truncated_items__: 5}
    assert metadata.params.data.api_key == "[REDACTED]"
    assert metadata.params.data.nested.client_secret == "[REDACTED]"
    assert metadata.params.data.__struct__ == inspect(CredentialsStruct)

    assert get_in(metadata, [:params, :nested, :layer1, :layer2]) == %{
             __truncated_depth__: 4,
             type: :map,
             size: 1
           }
  end

  test "sanitize_value keeps deep structs inspect-safe" do
    request = Req.new(url: "https://example.com", auth: {:bearer, "token-123"})
    sanitized = Telemetry.sanitize_value(%{layer1: %{layer2: %{request: request}}})
    sanitized_request = get_in(sanitized, [:layer1, :layer2, :request])

    assert_struct_summary(sanitized_request, Req.Request, map_size(request))
  end

  test "emit_end_event sanitizes result payloads" do
    long_string = String.duplicate("z", 280)

    assert :ok =
             Telemetry.emit_end_event(
               __MODULE__,
               %{input: 1},
               %{secret: "hidden"},
               {:ok, %{token: "tok-123", payload: long_string}}
             )

    assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, metadata}

    assert metadata.context.secret == "[REDACTED]"
    assert {:ok, result_payload} = metadata.result
    assert result_payload.token == "[REDACTED]"
    assert String.contains?(result_payload.payload, "...(truncated 24 bytes)")
  end

  test "struct with custom Inspect at depth >= 4 does not crash safe_inspect" do
    deep_struct =
      %{
        l1: %{
          l2: %{
            l3: %{
              l4: %CustomInspectStruct{
                entries: [1, 2, 3],
                name: "test"
              }
            }
          }
        }
      }

    sanitized = Telemetry.sanitize_value(deep_struct)
    l4 = get_in(sanitized, [:l1, :l2, :l3, :l4])

    assert_struct_summary(l4, CustomInspectStruct, map_size(%CustomInspectStruct{}))
  end

  test "struct with custom Inspect at depth < 4 keeps __struct__ marker as string" do
    shallow_struct =
      %{
        l1: %{
          data: %CustomInspectStruct{
            entries: [1, 2, 3],
            name: "test"
          }
        }
      }

    sanitized = Telemetry.sanitize_value(shallow_struct)
    data = get_in(sanitized, [:l1, :data])

    assert data.__struct__ == inspect(CustomInspectStruct)
    assert data.entries == [1, 2, 3]
    assert data.name == "test"

    # Inspecting the sanitized value does not crash
    inspected = inspect(sanitized)
    refute String.starts_with?(inspected, "#Inspect.Error<")
  end

  test "safe_inspect does not produce Inspect.Error for deeply nested custom structs" do
    deep_struct =
      %{
        l1: %{
          l2: %{
            l3: %CustomInspectStruct{
              entries: [1, 2, 3],
              name: "test"
            }
          }
        }
      }

    log =
      capture_log(fn ->
        Telemetry.cond_log_start(:notice, __MODULE__, deep_struct, %{})
      end)

    refute log =~ "Inspect.Error"
    assert log =~ "CustomInspectStruct"
    assert log =~ "type: :struct"
  end

  test "safe_inspect keeps nested Zoi structs inspect-safe while preserving module info" do
    deep_struct = %{l1: %{l2: %{l3: %Zoi.Types.Map{fields: [foo: %Zoi.Types.String{}]}}}}

    log =
      capture_log(fn ->
        Telemetry.cond_log_start(:notice, __MODULE__, deep_struct, %{})
      end)

    refute log =~ "Inspect.Error"
    assert log =~ "Zoi.Types.Map"
    assert log =~ "type: :struct"
  end

  test "struct keys with raising Inspect implementations are sanitized before logging" do
    struct_key = %RaisingInspectStruct{value: 1}
    sanitized = Telemetry.sanitize_value(%{struct_key => :value})
    [sanitized_key] = Map.keys(sanitized)

    refute is_struct(sanitized_key)
    assert sanitized_key.__struct__ == inspect(RaisingInspectStruct)
    assert sanitized[sanitized_key] == :value

    log =
      capture_log(fn ->
        Telemetry.cond_log_start(:notice, __MODULE__, %{struct_key => :value}, %{})
      end)

    refute log =~ "Inspect.Error"
    assert log =~ "RaisingInspectStruct"
    assert log =~ "=> :value"
  end

  test "deep struct values are summarized without leaking sensitive fields or long binaries" do
    long_string = String.duplicate("x", 300)

    creds = %CredentialsStruct{
      api_key: "api-123",
      note: long_string,
      nested: %{client_secret: "nested-secret"}
    }

    sanitized = Telemetry.sanitize_value(%{l1: %{l2: %{creds: creds}}})
    creds_summary = get_in(sanitized, [:l1, :l2, :creds])

    assert_struct_summary(creds_summary, CredentialsStruct, map_size(creds))

    inspected = inspect(sanitized)
    refute inspected =~ "api-123"
    refute inspected =~ "nested-secret"
    refute inspected =~ long_string
  end

  test "deep struct values with raising Inspect implementations stay inspect-safe" do
    payload = %{l1: %{l2: %{bad: %RaisingInspectStruct{value: 1}}}}
    sanitized = Telemetry.sanitize_value(payload)
    bad_summary = get_in(sanitized, [:l1, :l2, :bad])

    assert_struct_summary(bad_summary, RaisingInspectStruct, map_size(%RaisingInspectStruct{}))

    log =
      capture_log(fn ->
        Telemetry.cond_log_start(:notice, __MODULE__, payload, %{})
      end)

    refute log =~ "Inspect.Error"
    assert log =~ "RaisingInspectStruct"
    assert log =~ "type: :struct"
  end

  describe "deep struct summarization (DateTime, URI, etc.)" do
    test "sanitize_value summarizes DateTime when near max depth" do
      dt = DateTime.utc_now()

      deep = %{l1: %{l2: %{dt: dt}}}
      sanitized_deep = Telemetry.sanitize_value(deep)
      dt_sanitized = get_in(sanitized_deep, [:l1, :l2, :dt])
      assert_struct_summary(dt_sanitized, DateTime, map_size(dt))

      # At shallow depth, struct is decomposed safely (fields don't hit max_depth)
      shallow = Telemetry.sanitize_value(%{dt: dt})
      assert is_map(shallow.dt)
      assert is_tuple(shallow.dt.microsecond)
    end

    test "sanitize_value summarizes NaiveDateTime" do
      ndt = NaiveDateTime.utc_now()
      sanitized = Telemetry.sanitize_value(%{l1: %{l2: %{ndt: ndt}}})
      ndt_sanitized = get_in(sanitized, [:l1, :l2, :ndt])
      assert_struct_summary(ndt_sanitized, NaiveDateTime, map_size(ndt))
    end

    test "sanitize_value summarizes Date" do
      d = Date.utc_today()
      sanitized = Telemetry.sanitize_value(%{l1: %{l2: %{d: d}}})
      d_sanitized = get_in(sanitized, [:l1, :l2, :d])
      assert_struct_summary(d_sanitized, Date, map_size(d))
    end

    test "sanitize_value summarizes Time" do
      t = Time.utc_now()
      sanitized = Telemetry.sanitize_value(%{l1: %{l2: %{t: t}}})
      t_sanitized = get_in(sanitized, [:l1, :l2, :t])
      assert_struct_summary(t_sanitized, Time, map_size(t))
    end

    test "sanitize_value summarizes URI" do
      uri = URI.parse("https://example.com/path?q=1")
      sanitized = Telemetry.sanitize_value(%{l1: %{l2: %{uri: uri}}})
      uri_sanitized = get_in(sanitized, [:l1, :l2, :uri])
      assert_struct_summary(uri_sanitized, URI, map_size(uri))
    end

    test "sanitize_value summarizes Regex" do
      regex = ~r/foo.*bar/i
      sanitized = Telemetry.sanitize_value(%{l1: %{l2: %{re: regex}}})
      re_sanitized = get_in(sanitized, [:l1, :l2, :re])
      assert_struct_summary(re_sanitized, Regex, map_size(regex))
    end

    test "sanitize_value summarizes MapSet" do
      ms = MapSet.new([1, 2, 3])
      sanitized = Telemetry.sanitize_value(%{l1: %{l2: %{ms: ms}}})
      ms_sanitized = get_in(sanitized, [:l1, :l2, :ms])
      assert_struct_summary(ms_sanitized, MapSet, map_size(ms))
    end

    test "sanitize_value summarizes Range" do
      range = 1..10
      sanitized = Telemetry.sanitize_value(%{l1: %{l2: %{r: range}}})
      r_sanitized = get_in(sanitized, [:l1, :l2, :r])
      assert_struct_summary(r_sanitized, Range, map_size(range))
    end

    test "sanitize_value summarizes Version" do
      {:ok, ver} = Version.parse("1.2.3")
      sanitized = Telemetry.sanitize_value(%{l1: %{l2: %{v: ver}}})
      v_sanitized = get_in(sanitized, [:l1, :l2, :v])
      assert_struct_summary(v_sanitized, Version, map_size(ver))
    end

    test "safe_inspect on deeply nested structs containing DateTimes never crashes" do
      deep = %{
        l1: %{
          l2: %{
            l3: %{
              dt: DateTime.utc_now(),
              ndt: NaiveDateTime.utc_now(),
              t: Time.utc_now()
            }
          }
        }
      }

      log =
        capture_log(fn ->
          Telemetry.cond_log_start(:notice, __MODULE__, deep, %{})
        end)

      refute log =~ "Inspect.Error"
      assert log =~ "DateTime"
      assert log =~ "type: :struct"
    end

    test "sanitized structs at truncation-triggering depth are safely inspectable and JSON-encodable" do
      data = %{
        l1: %{
          l2: %{
            dt: DateTime.utc_now(),
            ndt: NaiveDateTime.utc_now(),
            d: Date.utc_today(),
            t: Time.utc_now(),
            uri: URI.parse("https://example.com"),
            re: ~r/test/,
            ms: MapSet.new([1, 2]),
            r: 1..5,
            v: Version.parse!("2.0.0")
          }
        }
      }

      sanitized = Telemetry.sanitize_value(data)
      l2 = get_in(sanitized, [:l1, :l2])

      # All should be typed truncation summaries for structs at depth 3
      for {_key, val} <- l2 do
        assert %{__truncated_depth__: 4, type: :struct, module: module, size: size} = val,
               "Expected struct summary, got: #{Kernel.inspect(val)}"

        assert is_binary(module)
        assert is_integer(size)
      end

      # inspect should not crash
      inspected = inspect(sanitized)
      refute String.starts_with?(inspected, "#Inspect.Error<")

      # JSON-encodable
      assert {:ok, _} = Jason.encode(sanitized)
    end
  end

  test "log helpers sanitize sensitive data and large payloads" do
    long_string = String.duplicate("a", 300)

    log =
      capture_log(fn ->
        Telemetry.log_execution_start(
          __MODULE__,
          %{api_key: "api-secret", payload: long_string},
          %{password: "pwd-123"}
        )

        Telemetry.log_execution_end(
          __MODULE__,
          %{},
          %{},
          {:ok, %{token: "t-123", payload: long_string}}
        )

        Telemetry.cond_log_start(
          :notice,
          __MODULE__,
          %{authorization: "Bearer 123"},
          %{client_secret: "very-secret"}
        )

        Telemetry.cond_log_end(
          :debug,
          __MODULE__,
          {:error, %{cookie: "session-cookie", note: long_string}}
        )
      end)

    assert log =~ "[REDACTED]"
    assert log =~ "...(truncated 44 bytes)"
    refute log =~ "api-secret"
    refute log =~ "pwd-123"
    refute log =~ "t-123"
    refute log =~ "Bearer 123"
    refute log =~ "session-cookie"
    refute log =~ "very-secret"
  end
end
