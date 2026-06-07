defmodule Jido.Tools.Files do
  @moduledoc """
  A collection of file system actions for common file operations.

  This module provides a set of actions for working with files and directories:
  - ReadFile: Reads content from a file
  - WriteFile: Writes content to a file with optional directory creation
  - CopyFile: Copies a file from source to destination
  - MoveFile: Moves/renames a file from source to destination
  - DeleteFile: Deletes a file or directory with optional recursive deletion
  - MakeDirectory: Creates a new directory with optional recursive creation
  - ListDirectory: Lists directory contents with optional pattern matching and recursion

  Each action is implemented as a separate submodule and follows the Jido.Action behavior.
  The actions provide comprehensive file system operations with error handling and options
  like recursive deletion, force flags, and parent directory creation.
  """

  alias Jido.Action

  @file_roots_config_key :file_tool_roots
  @file_roots_context_keys [:allowed_file_roots, "allowed_file_roots", :file_roots, "file_roots"]
  @max_symlink_depth 40

  @doc false
  @spec resolve_path(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(path, context) when is_binary(path) do
    with {:ok, roots} <- active_file_roots(context) do
      case roots do
        [] ->
          {:ok, path}

        [default_root | _] = allowed_roots ->
          expanded_path = expand_candidate_path(path, default_root)

          with {:ok, guard_path} <- nearest_real_existing_path(expanded_path),
               :ok <- ensure_inside_allowed_roots(guard_path, allowed_roots) do
            {:ok, expanded_path}
          end
      end
    end
  end

  def resolve_path(_path, _context), do: {:error, "Invalid file path"}

  @doc false
  @spec validate_glob_pattern(String.t(), map()) :: :ok | {:error, String.t()}
  def validate_glob_pattern(pattern, context) when is_binary(pattern) do
    with {:ok, roots} <- active_file_roots(context) do
      cond do
        roots == [] ->
          :ok

        Path.type(pattern) == :absolute ->
          {:error, "Glob pattern must be relative when file roots are enforced"}

        String.contains?(pattern, "..") ->
          {:error, "Glob pattern cannot traverse parent directories when file roots are enforced"}

        true ->
          :ok
      end
    end
  end

  def validate_glob_pattern(_pattern, _context), do: {:error, "Invalid glob pattern"}

  @doc false
  @spec filter_allowed_paths([String.t()], map()) :: [String.t()]
  def filter_allowed_paths(paths, context) when is_list(paths) do
    case active_file_roots(context) do
      {:ok, []} ->
        paths

      {:ok, _roots} ->
        Enum.filter(paths, fn path ->
          match?({:ok, _}, resolve_path(path, context))
        end)

      {:error, _reason} ->
        []
    end
  end

  @doc false
  @spec reject_protected_delete_target(String.t()) :: :ok | {:error, String.t()}
  def reject_protected_delete_target(path) do
    expanded = Path.expand(path)

    protected_paths =
      [Path.expand("/"), File.cwd!(), user_home()]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Path.expand/1)

    if expanded in protected_paths do
      {:error, "Refusing to delete protected path: #{expanded}"}
    else
      :ok
    end
  end

  @doc false
  @spec reject_unsafe_nonrecursive_delete(String.t(), boolean()) :: :ok | {:error, String.t()}
  def reject_unsafe_nonrecursive_delete(path, force) do
    if force and File.dir?(path) do
      {:error, "Refusing to force-delete directory without recursive: true"}
    else
      :ok
    end
  end

  defp active_file_roots(context) do
    with {:ok, configured_roots} <-
           normalize_roots(Application.get_env(:jido_action, @file_roots_config_key, [])),
         {:ok, context_roots} <- normalize_roots(context_file_roots(context)),
         {:ok, configured_roots} <- canonicalize_roots(configured_roots),
         {:ok, context_roots} <- canonicalize_roots(context_roots) do
      cond do
        configured_roots == [] and context_roots == [] ->
          {:ok, []}

        configured_roots == [] ->
          {:ok, context_roots}

        context_roots == [] ->
          {:ok, configured_roots}

        true ->
          scoped_roots =
            Enum.filter(context_roots, fn context_root ->
              inside_any_root?(context_root, configured_roots)
            end)

          case scoped_roots do
            [] -> {:error, "No context file roots are within configured file roots"}
            roots -> {:ok, roots}
          end
      end
    end
  end

  defp context_file_roots(context) when is_map(context) do
    Enum.find_value(@file_roots_context_keys, fn key -> Map.get(context, key) end)
  end

  defp context_file_roots(_context), do: nil

  defp normalize_roots(nil), do: {:ok, []}
  defp normalize_roots(root) when is_binary(root), do: {:ok, [root]}

  defp normalize_roots(roots) when is_list(roots) do
    if Enum.all?(roots, &is_binary/1) do
      {:ok, roots}
    else
      {:error, "File roots must be strings"}
    end
  end

  defp normalize_roots(_roots), do: {:error, "File roots must be a string or list of strings"}

  defp canonicalize_roots(roots) do
    roots
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn root, {:ok, acc} ->
      root
      |> Path.expand()
      |> real_path()
      |> case do
        {:ok, real_path} -> {:cont, {:ok, [real_path | acc]}}
        {:error, reason} -> {:halt, {:error, "Allowed file root is invalid: #{inspect(reason)}"}}
      end
    end)
    |> case do
      {:ok, roots} -> {:ok, roots |> Enum.reverse() |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expand_candidate_path(path, default_root) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _relative -> Path.expand(path, default_root)
    end
  end

  defp nearest_real_existing_path(path) do
    with {:ok, existing_path} <- nearest_existing_path(Path.expand(path)) do
      case real_path(existing_path) do
        {:ok, real_path} -> {:ok, real_path}
        {:error, reason} -> {:error, "Failed to resolve file path: #{inspect(reason)}"}
      end
    end
  end

  defp real_path(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_real_path_parts(nil, 0)
  end

  defp resolve_real_path_parts([], nil, _symlink_depth), do: {:error, :enoent}

  defp resolve_real_path_parts([root | rest], nil, symlink_depth) do
    resolve_real_path_parts(rest, root, symlink_depth)
  end

  defp resolve_real_path_parts([], resolved_path, _symlink_depth), do: {:ok, resolved_path}

  defp resolve_real_path_parts([part | rest], resolved_path, symlink_depth) do
    candidate = Path.join(resolved_path, part)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        resolve_symlink(candidate, resolved_path, rest, symlink_depth)

      {:ok, _stat} ->
        resolve_real_path_parts(rest, candidate, symlink_depth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_symlink(_candidate, _parent, _rest, symlink_depth)
       when symlink_depth >= @max_symlink_depth do
    {:error, :too_many_symlinks}
  end

  defp resolve_symlink(candidate, parent, rest, symlink_depth) do
    case :file.read_link(String.to_charlist(candidate)) do
      {:ok, target} ->
        target_path =
          target
          |> List.to_string()
          |> expand_symlink_target(parent)

        target_parts = Path.split(target_path) ++ rest
        resolve_real_path_parts(target_parts, nil, symlink_depth + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expand_symlink_target(target, parent) do
    case Path.type(target) do
      :absolute -> Path.expand(target)
      _relative -> Path.expand(target, parent)
    end
  end

  defp nearest_existing_path(path) do
    case File.lstat(path) do
      {:ok, _stat} ->
        {:ok, path}

      {:error, _reason} ->
        parent = Path.dirname(path)

        if parent == path do
          {:error, "No existing parent directory for file path"}
        else
          nearest_existing_path(parent)
        end
    end
  end

  defp ensure_inside_allowed_roots(path, allowed_roots) do
    if inside_any_root?(path, allowed_roots) do
      :ok
    else
      {:error, "File path is outside allowed file roots"}
    end
  end

  defp inside_any_root?(path, roots), do: Enum.any?(roots, &inside_root?(path, &1))

  defp inside_root?(_path, "/"), do: true
  defp inside_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp user_home do
    System.user_home!()
  rescue
    _ -> nil
  end

  defmodule ReadFile do
    @moduledoc false
    use Action,
      name: "read_file",
      description: "Reads content from a file",
      schema: [
        path: [type: :string, required: true, doc: "Path to the file to be read"]
      ]

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path}, context) do
      with {:ok, resolved_path} <- Jido.Tools.Files.resolve_path(path, context) do
        case File.read(resolved_path) do
          {:ok, content} -> {:ok, %{path: resolved_path, content: content}}
          {:error, reason} -> {:error, "Failed to read file: #{inspect(reason)}"}
        end
      end
    end
  end

  defmodule WriteFile do
    @moduledoc false
    use Action,
      name: "write_file",
      description: "Writes content to a file, optionally creating parent directories",
      schema: [
        path: [type: :string, required: true, doc: "Path to the file to be written"],
        content: [type: :string, required: true, doc: "Content to be written to the file"],
        create_dirs: [
          type: :boolean,
          default: false,
          doc: "Create parent directories if they don't exist"
        ],
        mode: [
          type: {:in, [:write, :append]},
          default: :write,
          doc: "Write mode - :write overwrites, :append adds to end"
        ]
      ]

    @impl true
    def run(%{path: path, content: content, create_dirs: create_dirs, mode: mode}, context) do
      with {:ok, resolved_path} <- Jido.Tools.Files.resolve_path(path, context),
           :ok <- maybe_create_parent_dirs(resolved_path, create_dirs),
           {:ok, resolved_path} <- Jido.Tools.Files.resolve_path(resolved_path, context) do
        case write_with_mode(resolved_path, content, mode) do
          :ok -> {:ok, %{path: resolved_path, bytes_written: byte_size(content)}}
          {:error, reason} -> {:error, "Failed to write file: #{inspect(reason)}"}
        end
      end
    end

    defp maybe_create_parent_dirs(path, true) do
      case File.mkdir_p(Path.dirname(path)) do
        :ok -> :ok
        {:error, reason} -> {:error, "Failed to write file: #{inspect(reason)}"}
      end
    end

    defp maybe_create_parent_dirs(_path, false), do: :ok

    defp write_with_mode(path, content, :write), do: File.write(path, content)
    defp write_with_mode(path, content, :append), do: File.write(path, content, [:append])
  end

  defmodule MakeDirectory do
    @moduledoc false
    use Action,
      name: "make_directory",
      description: "Creates a new directory, optionally creating parent directories",
      schema: [
        path: [type: :string, required: true, doc: "Path to the directory to create"],
        recursive: [
          type: :boolean,
          default: false,
          doc: "Create parent directories if they don't exist"
        ]
      ]

    @impl true
    def run(%{path: path, recursive: true}, context) do
      with {:ok, resolved_path} <- Jido.Tools.Files.resolve_path(path, context) do
        case File.mkdir_p(resolved_path) do
          :ok ->
            case Jido.Tools.Files.resolve_path(resolved_path, context) do
              {:ok, _resolved_path} -> {:ok, %{path: resolved_path}}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, "Failed to create directory: #{inspect(reason)}"}
        end
      end
    end

    def run(%{path: path, recursive: false}, context) do
      with {:ok, resolved_path} <- Jido.Tools.Files.resolve_path(path, context) do
        case File.mkdir(resolved_path) do
          :ok ->
            case Jido.Tools.Files.resolve_path(resolved_path, context) do
              {:ok, _resolved_path} -> {:ok, %{path: resolved_path}}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, "Failed to create directory: #{inspect(reason)}"}
        end
      end
    end
  end

  defmodule ListDirectory do
    @moduledoc false
    use Action,
      name: "list_directory",
      description: "Lists directory contents with optional pattern matching",
      schema: [
        path: [type: :string, required: true, doc: "Path to the directory to list"],
        pattern: [
          type: :string,
          doc: "Optional glob pattern for filtering files",
          required: false
        ],
        recursive: [
          type: :boolean,
          default: false,
          doc: "Include subdirectories recursively"
        ]
      ]

    @impl true
    def run(%{path: path, pattern: pattern, recursive: recursive}, context)
        when is_binary(pattern) do
      with {:ok, resolved_path} <- Jido.Tools.Files.resolve_path(path, context),
           :ok <- Jido.Tools.Files.validate_glob_pattern(pattern, context) do
        result =
          case recursive do
            true -> Path.wildcard(Path.join(resolved_path, pattern))
            false -> Path.wildcard(Path.join(resolved_path, pattern)) |> Enum.reject(&File.dir?/1)
          end
          |> Jido.Tools.Files.filter_allowed_paths(context)

        {:ok, %{entries: result}}
      end
    end

    def run(%{path: path, recursive: recursive}, context) do
      with {:ok, resolved_path} <- Jido.Tools.Files.resolve_path(path, context) do
        case recursive do
          true ->
            case File.ls(resolved_path) do
              {:ok, entries} -> {:ok, %{entries: entries}}
              {:error, reason} -> {:error, "Failed to list directory: #{inspect(reason)}"}
            end

          false ->
            case File.ls(resolved_path) do
              {:ok, entries} ->
                files = Enum.reject(entries, &File.dir?(Path.join(resolved_path, &1)))
                {:ok, %{entries: files}}

              {:error, reason} ->
                {:error, "Failed to list directory: #{inspect(reason)}"}
            end
        end
      end
    end
  end

  defmodule DeleteFile do
    @moduledoc false
    use Action,
      name: "delete_file",
      description: "Deletes a file or directory with optional recursive deletion",
      schema: [
        path: [type: :string, required: true, doc: "Path to delete"],
        recursive: [
          type: :boolean,
          default: false,
          doc: "Recursively delete directories and contents"
        ],
        force: [
          type: :boolean,
          default: false,
          doc: "Force deletion even if file is read-only"
        ]
      ]

    @impl true
    def run(%{path: path, recursive: true}, context) do
      with {:ok, resolved_path} <- Jido.Tools.Files.resolve_path(path, context),
           :ok <- Jido.Tools.Files.reject_protected_delete_target(resolved_path) do
        case File.rm_rf(resolved_path) do
          {:ok, paths} ->
            {:ok, %{deleted: paths}}

          {:error, reason, paths} ->
            {:error,
             "Failed to delete some paths: #{inspect(reason)}, deleted: #{inspect(paths)}"}
        end
      end
    end

    def run(%{path: path, recursive: false, force: force}, context) do
      with {:ok, resolved_path} <- Jido.Tools.Files.resolve_path(path, context),
           :ok <- Jido.Tools.Files.reject_protected_delete_target(resolved_path),
           :ok <- Jido.Tools.Files.reject_unsafe_nonrecursive_delete(resolved_path, force) do
        result =
          if force do
            case File.rm_rf(resolved_path) do
              {:ok, _paths} -> :ok
              {:error, reason, _paths} -> {:error, reason}
            end
          else
            File.rm(resolved_path)
          end

        case result do
          :ok -> {:ok, %{path: resolved_path}}
          {:error, reason} -> {:error, "Failed to delete: #{inspect(reason)}"}
        end
      end
    end
  end

  defmodule CopyFile do
    @moduledoc false
    use Action,
      name: "copy_file",
      description: "Copies a file from source to destination",
      schema: [
        source: [type: :string, required: true, doc: "Path to the source file"],
        destination: [type: :string, required: true, doc: "Path to the destination file"]
      ]

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{source: source, destination: destination}, context) do
      with {:ok, resolved_source} <- Jido.Tools.Files.resolve_path(source, context),
           {:ok, resolved_destination} <- Jido.Tools.Files.resolve_path(destination, context) do
        case File.copy(resolved_source, resolved_destination) do
          {:ok, bytes_copied} ->
            {:ok,
             %{
               source: resolved_source,
               destination: resolved_destination,
               bytes_copied: bytes_copied
             }}

          {:error, reason} ->
            {:error, "Failed to copy file: #{inspect(reason)}"}
        end
      end
    end
  end

  defmodule MoveFile do
    @moduledoc false
    use Action,
      name: "move_file",
      description: "Moves a file from source to destination",
      schema: [
        source: [type: :string, required: true, doc: "Path to the source file"],
        destination: [type: :string, required: true, doc: "Path to the destination file"]
      ]

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{source: source, destination: destination}, context) do
      with {:ok, resolved_source} <- Jido.Tools.Files.resolve_path(source, context),
           {:ok, resolved_destination} <- Jido.Tools.Files.resolve_path(destination, context) do
        case File.rename(resolved_source, resolved_destination) do
          :ok -> {:ok, %{source: resolved_source, destination: resolved_destination}}
          {:error, reason} -> {:error, "Failed to move file: #{inspect(reason)}"}
        end
      end
    end
  end
end
