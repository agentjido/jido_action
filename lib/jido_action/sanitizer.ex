defmodule Jido.Action.Sanitizer do
  @moduledoc """
  Shared structural sanitizer for transport-safe and telemetry-safe values.

  The default `:transport` profile recursively converts arbitrary Elixir terms
  into plain, Jason-safe data suitable for normalized error payloads and
  cross-package boundaries. Structs become plain maps with a string
  `:__struct__` marker, exceptions also keep `:__exception__`, tuples become
  lists, and inspect-hostile terms fall back to safe string representations.

  The `:telemetry` profile preserves the existing execution telemetry behavior:
  sensitive-key redaction, payload truncation, depth caps, and inspect-safe
  struct summaries.

  ## Examples

      iex> Jido.Action.Sanitizer.sanitize({:ok, %URI{scheme: "https", host: "example.com"}})
      [:ok, %{__struct__: "URI", scheme: "https", host: "example.com", path: nil, port: 443, query: nil, authority: "example.com", fragment: nil, userinfo: nil}]

      iex> Jido.Action.Sanitizer.sanitize_telemetry(%{token: "secret", payload: String.duplicate("a", 300)})
      %{token: "[REDACTED]", payload: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...(truncated 44 bytes)"}
  """

  @type profile :: :transport | :telemetry

  @redacted_value "[REDACTED]"
  @max_depth 4
  @max_collection_items 25
  @max_binary_bytes 256
  @sensitive_patterns [
    "password",
    "passwd",
    "passphrase",
    "secret",
    "token",
    "apikey",
    "accesskey",
    "privatekey",
    "authorization",
    "auth",
    "cookie",
    "session",
    "credential"
  ]
  @inspect_opts [charlists: :as_lists, printable_limit: :infinity, limit: :infinity]

  @doc """
  Sanitizes a value using the requested profile.
  """
  @spec sanitize(term(), keyword()) :: term()
  def sanitize(value, opts \\ []) do
    case Keyword.get(opts, :profile, :transport) do
      :transport -> sanitize_transport(value)
      :telemetry -> do_sanitize_with_telemetry_profile(value, opts)
      profile -> raise ArgumentError, "unsupported sanitizer profile: #{inspect(profile)}"
    end
  end

  @doc """
  Sanitizes a value using the telemetry profile.
  """
  @spec sanitize_telemetry(term(), keyword()) :: term()
  def sanitize_telemetry(value, opts \\ []) do
    opts
    |> Keyword.put(:profile, :telemetry)
    |> then(&sanitize(value, &1))
  end

  defp sanitize_transport(value)

  defp sanitize_transport(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value) or
              is_binary(value),
       do: value

  defp sanitize_transport(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> sanitize_transport_map()
    |> Map.put(:__struct__, normalize_struct_marker(struct.__struct__))
    |> maybe_put_exception_marker(struct)
  end

  defp sanitize_transport(value) when is_map(value), do: sanitize_transport_map(value)

  defp sanitize_transport(value) when is_list(value) do
    case list_parts(value) do
      {:proper, items} ->
        Enum.map(items, &sanitize_transport/1)

      {:improper, items, tail} ->
        %{
          __type__: :improper_list,
          items: Enum.map(items, &sanitize_transport/1),
          tail: sanitize_transport(tail)
        }
    end
  end

  defp sanitize_transport(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&sanitize_transport/1)
  end

  defp sanitize_transport(value) when is_pid(value),
    do: List.to_string(:erlang.pid_to_list(value))

  defp sanitize_transport(value) when is_reference(value),
    do: List.to_string(:erlang.ref_to_list(value))

  defp sanitize_transport(value) when is_port(value),
    do: List.to_string(:erlang.port_to_list(value))

  defp sanitize_transport(value), do: safe_inspect(value)

  defp sanitize_transport_map(map) do
    map
    |> Map.to_list()
    |> Enum.map(fn {key, value} ->
      sanitized_key = sanitize_transport_key(key)
      {sanitized_key, safe_inspect(sanitized_key), sanitize_transport(value)}
    end)
    |> Enum.sort_by(fn {_sanitized_key, sort_key, _sanitized_value} -> sort_key end)
    |> Enum.map(fn {sanitized_key, _sort_key, sanitized_value} ->
      {sanitized_key, sanitized_value}
    end)
    |> Map.new()
  end

  defp sanitize_transport_key(key)
       when is_atom(key) or is_binary(key) or is_number(key) or is_boolean(key) or is_nil(key),
       do: key

  defp sanitize_transport_key(key) do
    key
    |> sanitize_transport()
    |> inspect_key()
  end

  defp inspect_key(key) when is_binary(key), do: key
  defp inspect_key(key) when is_atom(key), do: Atom.to_string(key)
  defp inspect_key(key) when is_number(key) or is_boolean(key), do: to_string(key)
  defp inspect_key(nil), do: "nil"
  defp inspect_key(key), do: safe_inspect(key)

  defp maybe_put_exception_marker(map, struct) do
    if is_exception(struct) do
      Map.put(map, :__exception__, true)
    else
      map
    end
  end

  defp do_sanitize_with_telemetry_profile(value, opts) do
    do_sanitize_telemetry(value, 0, telemetry_opts(opts))
  end

  defp telemetry_opts(opts) do
    %{
      redacted_value: Keyword.get(opts, :redacted_value, @redacted_value),
      max_depth: Keyword.get(opts, :max_depth, @max_depth),
      max_collection_items: Keyword.get(opts, :max_collection_items, @max_collection_items),
      max_binary_bytes: Keyword.get(opts, :max_binary_bytes, @max_binary_bytes),
      sensitive_patterns: Keyword.get(opts, :sensitive_patterns, @sensitive_patterns)
    }
  end

  defp do_sanitize_telemetry(value, depth, opts) when depth >= opts.max_depth do
    summarize_truncated(value, opts)
  end

  defp do_sanitize_telemetry(%_{} = struct, depth, opts) when depth + 1 >= opts.max_depth do
    summarize_truncated_struct(struct, opts)
  end

  defp do_sanitize_telemetry(%_{} = struct, depth, opts) do
    struct
    |> Map.from_struct()
    |> do_sanitize_telemetry(depth, opts)
    |> Map.put(:__struct__, normalize_struct_marker(struct.__struct__))
  end

  defp do_sanitize_telemetry(value, depth, opts) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.map(fn {key, raw_value} ->
      {sanitize_telemetry_key(key, depth + 1, opts), key, raw_value}
    end)
    |> Enum.sort_by(fn {sanitized_key, _key, _value} -> safe_inspect(sanitized_key) end)
    |> Enum.split(opts.max_collection_items)
    |> then(fn {kept, dropped} ->
      sanitized =
        kept
        |> Enum.map(fn {sanitized_key, key, raw_value} ->
          sanitized_value =
            if sensitive_key?(key, opts) do
              opts.redacted_value
            else
              do_sanitize_telemetry(raw_value, depth + 1, opts)
            end

          {sanitized_key, sanitized_value}
        end)
        |> Map.new()

      if dropped == [] do
        sanitized
      else
        Map.put(sanitized, :__truncated_fields__, length(dropped))
      end
    end)
  end

  defp do_sanitize_telemetry(value, depth, opts) when is_list(value) do
    case list_parts(value) do
      {:proper, items} ->
        {kept, dropped} = Enum.split(items, opts.max_collection_items)
        sanitized = Enum.map(kept, &do_sanitize_telemetry(&1, depth + 1, opts))

        if dropped == [] do
          sanitized
        else
          sanitized ++ [%{__truncated_items__: length(dropped)}]
        end

      {:improper, items, tail} ->
        {kept, dropped} = Enum.split(items, opts.max_collection_items)

        improper =
          %{
            __type__: :improper_list,
            items: Enum.map(kept, &do_sanitize_telemetry(&1, depth + 1, opts)),
            tail: do_sanitize_telemetry(tail, depth + 1, opts)
          }

        if dropped == [] do
          improper
        else
          Map.put(improper, :__truncated_items__, length(dropped))
        end
    end
  end

  defp do_sanitize_telemetry(value, depth, opts) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> do_sanitize_telemetry(depth, opts)
    |> List.to_tuple()
  end

  defp do_sanitize_telemetry(value, _depth, opts) when is_binary(value) do
    if byte_size(value) > opts.max_binary_bytes do
      kept = binary_part(value, 0, opts.max_binary_bytes)
      truncated = byte_size(value) - opts.max_binary_bytes
      "#{kept}...(truncated #{truncated} bytes)"
    else
      value
    end
  end

  defp do_sanitize_telemetry(value, _depth, _opts), do: value

  defp sensitive_key?(key, opts) when is_atom(key), do: sensitive_key?(Atom.to_string(key), opts)

  defp sensitive_key?(key, opts) when is_binary(key) do
    normalized = key |> String.downcase() |> String.replace(~r/[^a-z0-9]/u, "")
    Enum.any?(opts.sensitive_patterns, &String.contains?(normalized, &1))
  end

  defp sensitive_key?(key, opts), do: sensitive_key?(safe_inspect(key), opts)

  defp sanitize_telemetry_key(key, _depth, _opts)
       when is_atom(key) or is_binary(key) or is_number(key) or is_boolean(key) or is_nil(key),
       do: key

  defp sanitize_telemetry_key(key, depth, opts), do: do_sanitize_telemetry(key, depth, opts)

  defp summarize_truncated(%_{} = struct, opts), do: summarize_truncated_struct(struct, opts)

  defp summarize_truncated(value, opts) when is_map(value) do
    %{__truncated_depth__: opts.max_depth, type: :map, size: map_size(value)}
  end

  defp summarize_truncated(value, opts) when is_list(value) do
    case list_parts(value) do
      {:proper, items} ->
        %{__truncated_depth__: opts.max_depth, type: :list, size: length(items)}

      {:improper, items, tail} ->
        %{
          __truncated_depth__: opts.max_depth,
          type: :improper_list,
          size: length(items),
          tail: safe_inspect(tail)
        }
    end
  end

  defp summarize_truncated(value, opts) when is_tuple(value) do
    %{__truncated_depth__: opts.max_depth, type: :tuple, size: tuple_size(value)}
  end

  defp summarize_truncated(value, opts) when is_binary(value) do
    do_sanitize_telemetry(value, opts.max_depth - 1, opts)
  end

  defp summarize_truncated(value, _opts), do: value

  defp summarize_truncated_struct(struct, opts) do
    %{
      __truncated_depth__: opts.max_depth,
      type: :struct,
      module: normalize_struct_marker(struct.__struct__),
      size: map_size(struct)
    }
  end

  defp normalize_struct_marker(mod) when is_atom(mod), do: inspect(mod)
  defp normalize_struct_marker(mod), do: mod

  defp safe_inspect(value) do
    inspect(value, @inspect_opts)
  rescue
    _ -> fallback_inspect(value)
  end

  defp fallback_inspect(value) when is_function(value), do: "#Function<uninspectable>"
  defp fallback_inspect(value) when is_pid(value), do: List.to_string(:erlang.pid_to_list(value))

  defp fallback_inspect(value) when is_reference(value),
    do: List.to_string(:erlang.ref_to_list(value))

  defp fallback_inspect(value) when is_port(value),
    do: List.to_string(:erlang.port_to_list(value))

  defp fallback_inspect(%_{} = struct) do
    "#Struct<#{normalize_struct_marker(struct.__struct__)}>"
  end

  defp fallback_inspect(value) when is_map(value), do: "#Map<size=#{map_size(value)}>"

  defp fallback_inspect(value) when is_list(value) do
    case list_parts(value) do
      {:proper, items} ->
        "#List<size=#{length(items)}>"

      {:improper, items, tail} ->
        "#ImproperList<size=#{length(items)}, tail=#{safe_inspect(tail)}>"
    end
  end

  defp fallback_inspect(value) when is_tuple(value), do: "#Tuple<size=#{tuple_size(value)}>"
  defp fallback_inspect(value) when is_binary(value), do: value
  defp fallback_inspect(value) when is_atom(value), do: Atom.to_string(value)
  defp fallback_inspect(value) when is_number(value), do: to_string(value)
  defp fallback_inspect(value) when is_boolean(value), do: to_string(value)
  defp fallback_inspect(nil), do: "nil"
  defp fallback_inspect(_value), do: "#Term<uninspectable>"

  defp list_parts(list), do: do_list_parts(list, [])

  defp do_list_parts([], acc), do: {:proper, Enum.reverse(acc)}
  defp do_list_parts([head | tail], acc), do: do_list_parts(tail, [head | acc])
  defp do_list_parts(tail, acc), do: {:improper, Enum.reverse(acc), tail}
end
