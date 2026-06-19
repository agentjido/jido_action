defmodule Jido.Flow.Script do
  @moduledoc """
  Restricted Elixir-term scripting for building `Jido.Flow` values.

  The script source is parsed with `Code.string_to_quoted/2`, then interpreted
  against a small allow-list of Flow-building forms. This is intentionally not a
  general Elixir evaluator.
  """

  alias Jido.Flow
  alias Jido.Flow.Script.{Parser, Renderer}

  @type option :: {:allowed_atoms, [atom()]}

  @doc """
  Parses a Flow script string into a `Jido.Flow`.

  Script atom parsing is hardened with a static atom encoder. Atoms must either
  already exist in the VM or be supplied through `:allowed_atoms`.
  """
  @spec parse(String.t(), [option()]) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def parse(source, opts \\ []) when is_binary(source) and is_list(opts) do
    with {:ok, quoted} <- string_to_quoted(source, opts),
         {:ok, flow} <- from_quoted(quoted) do
      {:ok, flow}
    end
  end

  @doc """
  Parses a Flow script string into a `Jido.Flow`, raising on errors.
  """
  @spec parse!(String.t(), [option()]) :: Flow.t()
  def parse!(source, opts \\ []) when is_binary(source) and is_list(opts) do
    case parse(source, opts) do
      {:ok, flow} -> flow
      {:error, error} -> raise error
    end
  end

  @doc """
  Parses a Flow script file into a `Jido.Flow`, raising on errors.
  """
  @spec parse_file!(Path.t(), [option()]) :: Flow.t()
  def parse_file!(path, opts \\ []) when is_list(opts) do
    path
    |> File.read!()
    |> parse!(opts)
  end

  @doc """
  Projects Flow IR back to normalized script syntax.

  Formatting and comments are not preserved. Semantic IR shape is preserved for
  supported script forms.
  """
  @spec to_script(Flow.t()) :: String.t()
  def to_script(%Flow{} = flow), do: Renderer.to_script(flow)

  @doc false
  @spec from_quoted(Macro.t()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def from_quoted(quoted), do: Parser.from_quoted(quoted)

  defp string_to_quoted(source, opts) do
    allowed_atoms = Keyword.get(opts, :allowed_atoms, [])
    atom_encoder = atom_encoder(allowed_atoms)

    case Code.string_to_quoted(source, columns: true, static_atoms_encoder: atom_encoder) do
      {:ok, quoted} ->
        {:ok, quoted}

      {:error, {_location, message, token}} ->
        {:error, ArgumentError.exception("invalid flow script: #{message}#{token}")}
    end
  end

  defp atom_encoder(allowed_atoms) do
    allowed =
      allowed_atoms
      |> Enum.map(fn
        atom when is_atom(atom) ->
          {Atom.to_string(atom), atom}

        other ->
          raise ArgumentError, "allowed_atoms must contain only atoms, got: #{inspect(other)}"
      end)
      |> Map.new()

    fn atom_string, _meta ->
      case Map.fetch(allowed, atom_string) do
        {:ok, atom} -> {:ok, atom}
        :error -> existing_atom(atom_string)
      end
    end
  end

  defp existing_atom(atom_string) do
    {:ok, String.to_existing_atom(atom_string)}
  rescue
    ArgumentError -> {:error, "unsafe atom does not exist: "}
  end
end
