defmodule Factory.GitHub.CLI do
  @moduledoc "GitHub access through the `gh` CLI, using the credentials of whoever runs the factory."
  @behaviour Factory.GitHub
  alias Factory.Shell

  @label_colors %{
    "factory:in-progress" => "2B50E6",
    "factory:in-review" => "8250DF",
    "factory:merged" => "0B8A68"
  }

  @impl true
  def list_issues(repo, label) do
    args =
      ~w(issue list -R #{repo} --state open --limit 50 --json number,title,body,url) ++
        ["--label", label]

    with {:ok, list} <- gh_json(args) do
      {:ok,
       Enum.map(
         list,
         &%{number: &1["number"], title: &1["title"], body: &1["body"] || "", url: &1["url"]}
       )}
    end
  end

  @impl true
  def get_issue(repo, number) do
    with {:ok, issue} <-
           gh_json(~w(issue view #{number} -R #{repo} --json title,body,state,comments)) do
      comments =
        for comment <- issue["comments"] || [] do
          {:ok, at, _} = DateTime.from_iso8601(comment["createdAt"])

          %{
            author: get_in(comment, ["author", "login"]) || "",
            body: comment["body"] || "",
            created_at: at
          }
        end

      {:ok,
       %{
         title: issue["title"],
         body: issue["body"] || "",
         state: issue["state"],
         comments: comments
       }}
    end
  end

  @impl true
  def comment(repo, number, body) do
    case Shell.run("gh", ~w(issue comment #{number} -R #{repo} --body-file -), stdin: body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, Shell.describe(reason)}
    end
  end

  @impl true
  def create_pr(repo, %{head: head, base: base, title: title, body: body}) do
    args =
      ~w(pr create -R #{repo} --head #{head} --base #{base} --body-file -) ++ ["--title", title]

    case Shell.run("gh", args, stdin: body) do
      {:ok, output} ->
        url = output |> String.split() |> Enum.find(&String.contains?(&1, "/pull/"))

        case url && Integer.parse(url |> String.split("/") |> List.last()) do
          {number, _} -> {:ok, %{number: number, url: url}}
          _ -> {:error, "could not read the PR url from: #{output}"}
        end

      {:error, reason} ->
        {:error, Shell.describe(reason)}
    end
  end

  @impl true
  def get_pr(repo, number) do
    with {:ok, pr} <- gh_json(~w(pr view #{number} -R #{repo} --json state)) do
      {:ok, %{state: pr["state"]}}
    end
  end

  @doc """
  The text of the submitted reviews of a pull request and their comments on
  lines. Either everything is read or nothing is: a failure on any of the two
  reads is returned as is.
  """
  @impl true
  def pr_review_comments(repo, number, fetch \\ &gh_lines/1) do
    with {:ok, reviews} <- fetch.("repos/#{repo}/pulls/#{number}/reviews"),
         {:ok, comments} <- fetch.("repos/#{repo}/pulls/#{number}/comments") do
      {:ok, review_comments(reviews, comments)}
    end
  end

  @doc """
  Turns the REST payloads of reviews and review comments into review comments.
  Pending (unsent) reviews and their comments, and empty texts, are left out. A
  comment on a line is dated when its review was submitted, not when it was drafted.
  """
  def review_comments(reviews, comments) do
    pending =
      for review <- reviews, review["state"] == "PENDING", into: MapSet.new(), do: review["id"]

    submitted =
      for review <- reviews, review["state"] != "PENDING", into: %{} do
        {review["id"], review["submitted_at"]}
      end

    texts =
      for review <- reviews, review["state"] != "PENDING", present?(review["body"]) do
        %{
          author: login(review),
          body: review["body"],
          created_at: datetime(review["submitted_at"]),
          path: nil,
          line: nil
        }
      end

    on_lines =
      for comment <- comments,
          not MapSet.member?(pending, comment["pull_request_review_id"]),
          present?(comment["body"]) do
        %{
          author: login(comment),
          body: comment["body"],
          created_at:
            datetime(
              Map.get(submitted, comment["pull_request_review_id"]) || comment["created_at"]
            ),
          path: comment["path"],
          line: comment["line"] || comment["original_line"]
        }
      end

    Enum.sort_by(texts ++ on_lines, & &1.created_at, DateTime)
  end

  defp present?(text), do: is_binary(text) and String.trim(text) != ""
  defp login(item), do: get_in(item, ["user", "login"]) || ""

  defp datetime(text) do
    {:ok, at, _} = DateTime.from_iso8601(text)
    at
  end

  @impl true
  def set_label(repo, number, label, true) do
    color = Map.get(@label_colors, label, "D93F0B")
    Shell.run("gh", ~w(label create #{label} -R #{repo} --force --color #{color}))
    Shell.run("gh", ~w(issue edit #{number} -R #{repo} --add-label #{label}))
    :ok
  end

  def set_label(repo, number, label, false) do
    Shell.run("gh", ~w(issue edit #{number} -R #{repo} --remove-label #{label}))
    :ok
  end

  @impl true
  def close_issue(repo, number, comment) do
    case Shell.run("gh", ~w(issue close #{number} -R #{repo} --comment) ++ [comment]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, Shell.describe(reason)}
    end
  end

  @impl true
  def current_user do
    case Shell.run("gh", ~w(api user --jq .login)) do
      {:ok, login} -> {:ok, String.trim(login)}
      {:error, reason} -> {:error, Shell.describe(reason)}
    end
  end

  # Every item of a paginated REST list, one JSON document per line.
  defp gh_lines(path) do
    case Shell.run("gh", ["api", path, "--paginate", "--jq", ".[] | @json"],
           timeout: :timer.seconds(60)
         ) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&(String.trim(&1) == ""))
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
          case Jason.decode(line) do
            {:ok, item} -> {:cont, {:ok, [item | acc]}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
        |> case do
          {:ok, items} -> {:ok, Enum.reverse(items)}
          error -> error
        end

      {:error, reason} ->
        {:error, Shell.describe(reason)}
    end
  end

  defp gh_json(args) do
    case Shell.run("gh", args, timeout: :timer.seconds(60)) do
      {:ok, output} -> Jason.decode(output)
      {:error, reason} -> {:error, Shell.describe(reason)}
    end
  end
end
