defmodule Jido.Tools.Github.IssueCommentsTest do
  use JidoTest.ActionCase, async: false

  import Mimic

  alias Jido.Tools.Github.IssueComments

  setup :set_mimic_global
  setup :verify_on_exit!

  @mock_client %{access_token: "test_token"}
  @mock_comment_response %{
    "id" => 456,
    "body" => "Looks good to me",
    "user" => %{"login" => "reviewer"}
  }

  describe "List" do
    test "lists issue comments successfully" do
      comments = [@mock_comment_response]

      expect(Tentacat.Issues.Comments, :list, fn client, owner, repo, number ->
        assert client == @mock_client
        assert owner == "test-owner"
        assert repo == "test-repo"
        assert number == 99
        comments
      end)

      params = %{client: @mock_client, owner: "test-owner", repo: "test-repo", number: 99}

      assert {:ok, result} = IssueComments.List.run(params, %{})
      assert result.status == "success"
      assert result.data == comments
      assert result.raw == comments
    end
  end

  describe "Create" do
    test "creates an issue comment successfully" do
      expect(Tentacat.Issues.Comments, :create, fn client, owner, repo, number, body ->
        assert client == @mock_client
        assert owner == "test-owner"
        assert repo == "test-repo"
        assert number == 99
        assert body == %{body: "Thanks for the report"}
        @mock_comment_response
      end)

      params = %{
        client: @mock_client,
        owner: "test-owner",
        repo: "test-repo",
        number: 99,
        body: "Thanks for the report"
      }

      assert {:ok, result} = IssueComments.Create.run(params, %{})
      assert result.status == "success"
      assert result.data == @mock_comment_response
      assert result.raw == @mock_comment_response
    end

    test "uses client from context" do
      expect(Tentacat.Issues.Comments, :create, fn client, _owner, _repo, _number, _body ->
        assert client == @mock_client
        @mock_comment_response
      end)

      params = %{owner: "test-owner", repo: "test-repo", number: 99, body: "Ack"}
      context = %{client: @mock_client}

      assert {:ok, result} = IssueComments.Create.run(params, context)
      assert result.status == "success"
    end
  end
end
