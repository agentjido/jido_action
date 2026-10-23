defmodule Jido.Flow.Inline.Owner do
  @moduledoc false

  @index_function {:__jido_inline_flows__, 0}

  @doc false
  @spec ensure_compiling!(Macro.Env.t()) :: :ok
  def ensure_compiling!(caller) do
    unless is_atom(caller.module) and not is_nil(caller.module) and
             is_nil(caller.function) and Module.open?(caller.module) do
      error!(caller, "inline Flow compilation requires a compiling owner module")
    end

    :ok
  end

  @doc false
  @spec setup!(Macro.Env.t()) :: :ok
  def setup!(caller) do
    ensure_compiling!(caller)

    unless Module.get_attribute(caller.module, :__jido_inline_flow_setup__) do
      reserve_index!(caller)
      Module.put_attribute(caller.module, :on_definition, {__MODULE__, :__on_definition__})
      Module.put_attribute(caller.module, :before_compile, __MODULE__)
      Module.put_attribute(caller.module, :__jido_inline_flow_setup__, true)
    end

    :ok
  end

  @doc false
  @spec __on_definition__(Macro.Env.t(), atom(), atom(), list(), list(), term()) :: :ok
  def __on_definition__(caller, _kind, name, args, _guards, _body) do
    function = {name, length(args)}
    generated = Module.get_attribute(caller.module, :__jido_inline_flow_generated__)

    if function == @index_function and generated != function do
      reserved_error!(caller)
    end

    :ok
  end

  @doc false
  @spec validate_path!(term(), Macro.Env.t()) :: Jido.Flow.Inline.path()
  def validate_path!(path, caller) do
    unless valid_path?(path) do
      error!(
        caller,
        "inline Flow identity must be a typed path with host, declaration, and role: :flow segments, got: #{inspect(path)}"
      )
    end

    path
  end

  defp valid_path?([{:host, _}, {_, _}, {_, _} | _] = path) do
    valid_segments?(path) and List.last(path) == {:role, :flow}
  end

  defp valid_path?(_path), do: false

  defp valid_segments?([]), do: true

  defp valid_segments?([{kind, value} | rest]) when is_atom(kind) do
    ((is_atom(value) and not is_nil(value)) or is_binary(value) or is_integer(value)) and
      valid_segments?(rest)
  end

  defp valid_segments?(_path), do: false

  @doc false
  @spec check_identity!(Jido.Flow.Inline.path(), Macro.Env.t()) :: :ok
  def check_identity!(path, caller) do
    index = Module.get_attribute(caller.module, :__jido_inline_flow_index__) || %{}

    if Map.has_key?(index, path) do
      error!(caller, "duplicate inline Flow identity: #{inspect(path)}")
    end

    :ok
  end

  @doc false
  @spec register!(Jido.Flow.Inline.path(), module(), Macro.Env.t()) :: :ok
  def register!(path, target, caller) do
    index = Module.get_attribute(caller.module, :__jido_inline_flow_index__) || %{}
    index = Map.put(index, path, target)
    Module.put_attribute(caller.module, :__jido_inline_flow_index__, index)

    if Module.defines?(caller.module, @index_function) do
      Module.delete_definition(caller.module, @index_function)
      Code.eval_quoted(index_definition(index), [], caller)
    end

    :ok
  end

  @doc false
  defmacro __before_compile__(caller) do
    index = Module.get_attribute(caller.module, :__jido_inline_flow_index__) || %{}
    index_definition(index)
  end

  defp index_definition(index) do
    quote generated: true do
      @__jido_inline_flow_generated__ {:__jido_inline_flows__, 0}
      @doc false
      @spec __jido_inline_flows__() :: %{optional(Jido.Flow.Inline.path()) => module()}
      def __jido_inline_flows__, do: unquote(Macro.escape(index))
      Module.delete_attribute(__MODULE__, :__jido_inline_flow_generated__)
    end
  end

  @doc false
  @spec target!(module(), Jido.Flow.Inline.path()) :: module()
  def target!(owner, path) do
    if is_atom(owner) and not is_nil(owner) and Module.open?(owner) do
      raise ArgumentError, "inline Flow lookup is available only after the owner compiles"
    end

    with true <- is_atom(owner) and not is_nil(owner) and valid_path?(path),
         true <- Code.ensure_loaded?(owner),
         true <- function_exported?(owner, :__jido_inline_flows__, 0),
         {:ok, target} <- Map.fetch(owner.__jido_inline_flows__(), path) do
      target
    else
      _ ->
        raise ArgumentError,
              "unknown inline Flow identity in #{inspect(owner)}: #{inspect(path)}"
    end
  end

  defp error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end

  defp reserve_index!(caller) do
    if Module.defines?(caller.module, @index_function), do: reserved_error!(caller)
    :ok
  end

  defp reserved_error!(caller) do
    error!(
      caller,
      "reserved inline Flow function __jido_inline_flows__/0 cannot have user clauses"
    )
  end
end
