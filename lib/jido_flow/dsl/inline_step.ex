defmodule Jido.Flow.DSL.InlineStep do
  @moduledoc false

  alias Jido.Action.Inline
  alias Jido.Flow.DSL.{InlineAction, MacroSupport}

  @doc false
  @spec parse!(Macro.t(), term(), Macro.Env.t()) :: Inline.t()
  def parse!(bindings, options, caller) do
    validate_options!(options, caller)

    parsed =
      try do
        Inline.parse_bound!(bindings, Keyword.take(options, [:do]), caller)
      rescue
        error in CompileError ->
          reraise %{
                    error
                    | description:
                        String.replace(error.description, "inline Action", "inline Step")
                  },
                  __STACKTRACE__
      end

    InlineAction.validate_sources!(bindings, caller, "inline Step")
    %{parsed | options: Keyword.delete(options, :do)}
  end

  @doc false
  @spec parse!(Macro.t(), Macro.t(), term(), Macro.Env.t()) :: Inline.t()
  def parse!(bindings, options, body_options, caller) when is_list(options),
    do: parse!(bindings, merge_options!(options, body_options, caller), caller)

  def parse!(left, right, options, caller), do: parse!([left, right], options, caller)

  @doc false
  @spec parse!(Macro.t(), Macro.t(), term(), term(), Macro.Env.t()) :: Inline.t()
  def parse!(left, right, options, body_options, caller),
    do: parse!([left, right], merge_options!(options, body_options, caller), caller)

  defp merge_options!(options, body_options, caller) do
    validate_options!(options, caller)
    validate_options!(body_options, caller)
    options ++ body_options
  end

  defp validate_options!(options, caller) do
    MacroSupport.validate_options!(
      options,
      caller,
      "inline Step options must be a keyword list",
      "inline Step field"
    )

    Enum.each(options, fn {field, _value} ->
      unless field in [:after, :meta, :do] do
        MacroSupport.compile_error!(
          caller,
          "unsupported inline Step field: #{inspect(field)}; use only after:, meta:, and do:"
        )
      end
    end)
  end
end
