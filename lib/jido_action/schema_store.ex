defmodule Jido.Action.SchemaStore do
  @moduledoc false

  defmodule Recipe do
    @moduledoc false

    @enforce_keys [:option, :bindings, :generation, :hash]
    defstruct [:option, :bindings, :generation, :hash]

    @type t :: %__MODULE__{
            option: :schema | :output_schema,
            bindings: keyword(),
            generation: binary(),
            hash: binary()
          }
  end

  @type option :: :schema | :output_schema
  @type builder :: (-> term())
  @type cache_state :: %{active: [{binary(), term()}], pending: {binary(), term()} | nil}

  @stage_key {__MODULE__, :staged}
  @expectation_key {__MODULE__, :expected_loads}
  @max_stages 32

  @doc false
  @spec prepare_source!(option(), Macro.t(), [atom()], Macro.Env.t()) :: Macro.t()
  def prepare_source!(option, source, binding_names, %Macro.Env{} = env)
      when option in [:schema, :output_schema] and is_list(binding_names) do
    validate_source!(option, source, env)
    normalize_binding_contexts(source, binding_names)
  end

  @doc false
  @spec recipe!(option(), keyword(), binary(), Macro.Env.t()) :: Recipe.t()
  def recipe!(option, bindings, generation, %Macro.Env{} = env)
      when option in [:schema, :output_schema] and is_list(bindings) and
             is_binary(generation) do
    validate_bindings!(option, bindings, env)

    %Recipe{
      option: option,
      bindings: bindings,
      generation: generation,
      hash: recipe_hash(option, generation)
    }
  end

  @doc false
  @spec expect_load(module(), [Recipe.t()]) :: :ok
  def expect_load(module, recipes) when is_atom(module) and is_list(recipes) do
    expectations =
      @expectation_key
      |> Process.get([])
      |> Enum.reject(fn {expected_module, _recipes} -> expected_module == module end)
      |> then(&[{module, recipes} | &1])
      |> Enum.take(@max_stages)

    Process.put(@expectation_key, expectations)
    :ok
  end

  @doc false
  @spec verify_loaded(Macro.Env.t(), binary()) :: :ok | no_return()
  def verify_loaded(%Macro.Env{module: module} = env, _bytecode) do
    recipes = pop_expected_load(module)

    missing_recipe = Enum.find(recipes, &(not active?(module, &1)))

    if missing_recipe do
      message =
        Enum.find_value(recipes, fn recipe -> load_error(module, recipe) end) ||
          "bound schema did not load"

      Enum.each(recipes, &clear_load_error(module, &1))

      raise CompileError,
        description: "Action bound schema load failed: #{message}",
        file: env.file,
        line: env.line
    end

    Enum.each(recipes, &clear_load_error(module, &1))
    :ok
  end

  @doc false
  @spec load!(module(), [{Recipe.t(), builder()}], (-> term())) :: :ok | term()
  def load!(module, builders, consumer_on_load)
      when is_atom(module) and is_list(builders) and is_function(consumer_on_load, 0) do
    schemas =
      Enum.map(builders, fn {%Recipe{} = recipe, builder} ->
        schema =
          case cached(module, recipe) do
            {:ok, cached_schema} -> cached_schema
            :missing -> build_and_validate!(module, recipe, builder)
          end

        {recipe, schema}
      end)

    previous_states = put_pending_schemas(module, schemas)
    stage(module, schemas)

    try do
      case consumer_on_load.() do
        :ok ->
          Enum.each(schemas, fn {recipe, schema} -> activate(module, recipe, schema) end)
          :ok

        other ->
          record_load_errors(
            module,
            schemas,
            "consumer @on_load returned #{inspect(other)}"
          )

          restore_states(previous_states)
          other
      end
    rescue
      error ->
        record_load_errors(module, schemas, Exception.message(error))
        restore_states(previous_states)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        record_load_errors(module, schemas, "#{kind}: #{inspect(reason)}")
        restore_states(previous_states)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      unstage(module)
    end
  end

  @doc false
  @spec fetch!(module(), Recipe.t(), builder()) :: term() | no_return()
  def fetch!(module, %Recipe{} = recipe, builder)
      when is_atom(module) and is_function(builder, 0) do
    case staged(module, recipe) do
      {:ok, schema} ->
        schema

      :missing ->
        case cached(module, recipe) do
          {:ok, schema} -> schema
          :missing -> rebuild_once!(module, recipe, builder)
        end
    end
  end

  @doc false
  @spec clear(module()) :: :ok
  def clear(module) when is_atom(module) do
    unstage(module)
    pop_expected_load(module)
    :persistent_term.erase(cache_key(module, :schema))
    :persistent_term.erase(cache_key(module, :output_schema))
    :persistent_term.erase(load_error_key(module, :schema))
    :persistent_term.erase(load_error_key(module, :output_schema))
    :ok
  end

  @doc false
  @spec portable?(term()) :: boolean()
  def portable?(term)
      when is_atom(term) or is_number(term) or is_bitstring(term),
      do: true

  def portable?(term) when is_function(term) do
    Function.info(term, :type) == {:type, :external}
  end

  def portable?([]), do: true

  def portable?([head | tail]) do
    portable?(head) and portable?(tail)
  end

  def portable?(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.all?(&portable?/1)
  end

  def portable?(term) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.all?(fn {key, value} -> portable?(key) and portable?(value) end)
  end

  def portable?(_term), do: false

  defp stage(module, schemas) do
    stages =
      @stage_key
      |> Process.get([])
      |> Enum.reject(fn {staged_module, _schemas} -> staged_module == module end)
      |> then(&[{module, schemas} | &1])
      |> Enum.take(@max_stages)

    Process.put(@stage_key, stages)
  end

  defp unstage(module) do
    remaining_stages =
      @stage_key
      |> Process.get([])
      |> Enum.reject(fn {staged_module, _schemas} -> staged_module == module end)

    case remaining_stages do
      [] -> Process.delete(@stage_key)
      stages -> Process.put(@stage_key, stages)
    end

    :ok
  end

  defp pop_expected_load(module) do
    expectations = Process.get(@expectation_key, [])

    case List.keytake(expectations, module, 0) do
      {{^module, recipes}, remaining_expectations} ->
        store_expectations(remaining_expectations)
        recipes

      nil ->
        []
    end
  end

  defp store_expectations([]), do: Process.delete(@expectation_key)
  defp store_expectations(expectations), do: Process.put(@expectation_key, expectations)

  defp staged(module, %Recipe{} = recipe) do
    case List.keyfind(Process.get(@stage_key, []), module, 0) do
      {^module, schemas} ->
        Enum.find_value(schemas, :missing, fn
          {%Recipe{hash: hash}, schema} when hash == recipe.hash -> {:ok, schema}
          _other_schema -> nil
        end)

      _other_stage ->
        :missing
    end
  end

  defp put_pending_schemas(module, schemas) do
    Enum.map(schemas, fn {%Recipe{} = recipe, schema} ->
      key = cache_key(module, recipe.option)
      previous = :persistent_term.get(key, :missing)
      state = if previous == :missing, do: empty_cache(), else: previous
      :persistent_term.put(key, %{state | pending: {recipe.hash, schema}})
      {key, previous}
    end)
  end

  defp restore_states(previous_states) do
    Enum.each(previous_states, fn
      {key, :missing} -> :persistent_term.erase(key)
      {key, state} -> :persistent_term.put(key, state)
    end)
  end

  defp activate(module, %Recipe{} = recipe, schema) do
    key = cache_key(module, recipe.option)
    state = :persistent_term.get(key, empty_cache())

    active =
      state.active
      |> Enum.reject(fn {hash, _schema} -> hash == recipe.hash end)
      |> then(&[{recipe.hash, schema} | &1])
      |> Enum.take(2)

    :persistent_term.put(key, %{active: active, pending: nil})
    clear_load_error(module, recipe)
    schema
  end

  defp active?(module, %Recipe{} = recipe) do
    module
    |> cache_state(recipe.option)
    |> Map.fetch!(:active)
    |> Enum.any?(fn {hash, _schema} -> hash == recipe.hash end)
  end

  defp cached(module, %Recipe{} = recipe) do
    state = :persistent_term.get(cache_key(module, recipe.option), empty_cache())

    Enum.find_value(state.active, fn
      {hash, schema} when hash == recipe.hash -> {:ok, schema}
      _other_generation -> nil
    end) ||
      case state.pending do
        {hash, schema} when hash == recipe.hash -> {:ok, schema}
        _other_pending -> :missing
      end
  end

  defp rebuild_once!(module, %Recipe{} = recipe, builder) do
    lock = {{__MODULE__, module, recipe.option}, self()}

    case :global.trans(
           lock,
           fn ->
             case cached(module, recipe) do
               {:ok, schema} -> schema
               :missing -> rebuild!(module, recipe, builder)
             end
           end,
           [node()]
         ) do
      {:aborted, reason} ->
        raise RuntimeError,
              "could not lock #{inspect(module)} #{inspect(recipe.option)}: #{inspect(reason)}"

      schema ->
        schema
    end
  end

  defp rebuild!(module, %Recipe{} = recipe, builder) do
    schema = build_and_validate!(module, recipe, builder)
    activate(module, recipe, schema)
  end

  defp build_and_validate!(module, %Recipe{} = recipe, builder) do
    schema = builder.()
    schema = if is_nil(schema), do: [], else: schema

    case Jido.Action.validate_action_schema(schema) do
      :ok ->
        schema

      {:error, message} ->
        raise RuntimeError,
              "could not load #{inspect(module)} #{inspect(recipe.option)}: #{message}"
    end
  rescue
    error ->
      record_load_error(module, recipe, Exception.message(error))
      reraise error, __STACKTRACE__
  end

  defp record_load_errors(module, schemas, message) do
    Enum.each(schemas, fn {recipe, _schema} -> record_load_error(module, recipe, message) end)
  end

  defp record_load_error(module, %Recipe{} = recipe, message) do
    :persistent_term.put(load_error_key(module, recipe.option), {recipe.hash, message})
  end

  defp load_error(module, %Recipe{} = recipe) do
    case :persistent_term.get(load_error_key(module, recipe.option), :missing) do
      {hash, message} when hash == recipe.hash -> message
      _other_error -> nil
    end
  end

  defp clear_load_error(module, %Recipe{} = recipe) do
    key = load_error_key(module, recipe.option)

    case :persistent_term.get(key, :missing) do
      {hash, _message} when hash == recipe.hash -> :persistent_term.erase(key)
      _other_error -> false
    end
  end

  defp validate_bindings!(option, bindings, env) do
    Enum.each(bindings, fn {name, value} ->
      unless portable?(value) do
        raise CompileError,
          description: "#{inspect(option)} binding #{inspect(name)} is not portable",
          file: env.file,
          line: env.line
      end
    end)
  end

  defp validate_source!(option, source, env) do
    if module_attribute_reference?(source) do
      bindings_option =
        if option == :schema, do: :schema_bindings, else: :output_schema_bindings

      raise CompileError,
        description:
          "#{inspect(option)} cannot read module attributes directly; " <>
            "pass each value through #{inspect(bindings_option)}",
        file: env.file,
        line: env.line
    end
  end

  defp normalize_binding_contexts(source, names) do
    do_normalize_binding_contexts(source, MapSet.new(names))
  end

  defp do_normalize_binding_contexts({:quote, _meta, _args} = source, _names), do: source

  defp do_normalize_binding_contexts({name, meta, context}, names)
       when is_atom(name) and is_list(meta) and is_atom(context) do
    if MapSet.member?(names, name), do: {name, meta, nil}, else: {name, meta, context}
  end

  defp do_normalize_binding_contexts(source, names) when is_list(source) do
    Enum.map(source, &do_normalize_binding_contexts(&1, names))
  end

  defp do_normalize_binding_contexts(source, names) when is_tuple(source) do
    source
    |> Tuple.to_list()
    |> Enum.map(&do_normalize_binding_contexts(&1, names))
    |> List.to_tuple()
  end

  defp do_normalize_binding_contexts(source, _names), do: source

  defp module_attribute_reference?({:@, _meta, _args}), do: true

  defp module_attribute_reference?(source) when is_list(source) do
    Enum.any?(source, &module_attribute_reference?/1)
  end

  defp module_attribute_reference?(source) when is_tuple(source) do
    source
    |> Tuple.to_list()
    |> Enum.any?(&module_attribute_reference?/1)
  end

  defp module_attribute_reference?(_source), do: false

  defp recipe_hash(option, generation) do
    {option, generation}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp cache_key(module, option), do: {__MODULE__, module, option}
  defp load_error_key(module, option), do: {__MODULE__, :load_error, module, option}

  defp cache_state(module, option),
    do: :persistent_term.get(cache_key(module, option), empty_cache())

  defp empty_cache, do: %{active: [], pending: nil}
end
