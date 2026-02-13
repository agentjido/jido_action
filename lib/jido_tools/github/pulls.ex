defmodule Jido.Tools.Github.Pulls do
  @moduledoc """
  Tools for interacting with GitHub Pull Requests API.

  Provides actions for creating, listing, finding, and updating GitHub pull requests.
  """

  defmodule List do
    @moduledoc "Action for listing all pull requests from a GitHub repository."

    use Jido.Action,
      name: "github_pulls_list",
      description: "List all pull requests from a GitHub repository",
      category: "Github API",
      tags: ["github", "pulls", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = Jido.Tools.Github.Helpers.client(params, context)
      result = Tentacat.Pulls.list(client, params.owner, params.repo)
      Jido.Tools.Github.Helpers.success(result)
    end
  end

  defmodule Find do
    @moduledoc "Action for finding a specific GitHub pull request by number."

    use Jido.Action,
      name: "github_pulls_find",
      description: "Get a specific pull request from GitHub",
      category: "Github API",
      tags: ["github", "pulls", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"],
        number: [type: :integer, doc: "The pull request number"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = Jido.Tools.Github.Helpers.client(params, context)
      result = Tentacat.Pulls.find(client, params.owner, params.repo, params.number)
      Jido.Tools.Github.Helpers.success(result)
    end
  end

  defmodule Create do
    @moduledoc "Action for creating a new GitHub pull request."

    use Jido.Action,
      name: "github_pulls_create",
      description: "Create a new pull request on GitHub",
      category: "Github API",
      tags: ["github", "pulls", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"],
        title: [type: :string, doc: "The title of the pull request"],
        body: [type: :string, doc: "The body of the pull request"],
        head: [type: :string, doc: "The name of the branch where your changes are implemented"],
        base: [type: :string, doc: "The name of the branch you want the changes pulled into"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = Jido.Tools.Github.Helpers.client(params, context)

      body =
        %{
          title: params[:title],
          body: params[:body],
          head: params[:head],
          base: params[:base]
        }
        |> Jido.Tools.Github.Helpers.compact_nil()

      result = Tentacat.Pulls.create(client, params.owner, params.repo, body)
      Jido.Tools.Github.Helpers.success(result)
    end
  end

  defmodule Update do
    @moduledoc "Action for updating an existing GitHub pull request."

    use Jido.Action,
      name: "github_pulls_update",
      description: "Update an existing pull request on GitHub",
      category: "Github API",
      tags: ["github", "pulls", "api"],
      vsn: "1.0.0",
      schema: [
        client: [type: :any, doc: "The Github client"],
        owner: [type: :string, doc: "The owner of the repository"],
        repo: [type: :string, doc: "The name of the repository"],
        number: [type: :integer, doc: "The pull request number"],
        title: [type: :string, doc: "The new title of the pull request"],
        body: [type: :string, doc: "The new body of the pull request"],
        state: [type: :string, doc: "The new state of the pull request (open, closed)"]
      ]

    @spec run(map(), map()) :: {:ok, map()} | {:error, Jido.Action.Error.t()}
    def run(params, context) do
      client = Jido.Tools.Github.Helpers.client(params, context)

      body =
        %{
          title: params[:title],
          body: params[:body],
          state: params[:state]
        }
        |> Jido.Tools.Github.Helpers.compact_nil()

      result = Tentacat.Pulls.update(client, params.owner, params.repo, params.number, body)
      Jido.Tools.Github.Helpers.success(result)
    end
  end
end
