defmodule Factory.GitHub.CLITest do
  use ExUnit.Case, async: true
  alias Factory.GitHub.CLI

  @reviews [
    %{
      "id" => 1,
      "state" => "COMMENTED",
      "body" => "Use a stream",
      "user" => %{"login" => "maintainer"},
      "submitted_at" => "2026-11-12T10:00:00Z"
    },
    %{
      "id" => 2,
      "state" => "PENDING",
      "body" => "Draft thoughts",
      "user" => %{"login" => "maintainer"},
      "submitted_at" => nil
    },
    %{
      "id" => 3,
      "state" => "APPROVED",
      "body" => "  ",
      "user" => %{"login" => "maintainer"},
      "submitted_at" => "2026-11-12T11:00:00Z"
    }
  ]

  @comments [
    %{
      "pull_request_review_id" => 3,
      "body" => "Too slow",
      "user" => %{"login" => "maintainer"},
      "path" => "lib/export.ex",
      "line" => nil,
      "original_line" => 12,
      "created_at" => "2026-11-12T09:00:00Z"
    },
    %{
      "pull_request_review_id" => 2,
      "body" => "Not sent yet",
      "user" => %{"login" => "maintainer"},
      "path" => "lib/export.ex",
      "line" => 3,
      "created_at" => "2026-11-12T09:30:00Z"
    }
  ]

  test "keeps the text of submitted reviews and their comments on lines" do
    assert [review, on_line] = CLI.review_comments(@reviews, @comments)

    assert review == %{
             author: "maintainer",
             body: "Use a stream",
             created_at: ~U[2026-11-12 10:00:00Z],
             path: nil,
             line: nil
           }

    # Without a current line it falls back to the original one, and it is dated
    # when its review was submitted, not when it was drafted.
    assert on_line == %{
             author: "maintainer",
             body: "Too slow",
             created_at: ~U[2026-11-12 11:00:00Z],
             path: "lib/export.ex",
             line: 12
           }
  end

  test "leaves out pending reviews, their comments and empty texts" do
    texts = @reviews |> CLI.review_comments(@comments) |> Enum.map(& &1.body)
    refute "Draft thoughts" in texts
    refute "Not sent yet" in texts
    refute Enum.any?(texts, &(String.trim(&1) == ""))
  end

  test "a comment whose review is unknown keeps its own date" do
    comment = %{hd(@comments) | "pull_request_review_id" => 99, "line" => 4}

    assert [%{created_at: ~U[2026-11-12 09:00:00Z], line: 4}] =
             CLI.review_comments([], [comment])
  end

  test "never returns a partial read" do
    reviews_fail = fn path ->
      if String.ends_with?(path, "/reviews"), do: {:error, "boom"}, else: {:ok, @comments}
    end

    comments_fail = fn path ->
      if String.ends_with?(path, "/comments"), do: {:error, "boom"}, else: {:ok, @reviews}
    end

    assert {:error, "boom"} = CLI.pr_review_comments("acme/app", 100, reviews_fail)
    assert {:error, "boom"} = CLI.pr_review_comments("acme/app", 100, comments_fail)

    both = fn path ->
      if String.ends_with?(path, "/reviews"), do: {:ok, @reviews}, else: {:ok, @comments}
    end

    assert {:ok, [_, _]} = CLI.pr_review_comments("acme/app", 100, both)
  end
end
