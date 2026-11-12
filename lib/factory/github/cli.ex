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

  defp gh_json(args) do
    case Shell.run("gh", args, timeout: :timer.seconds(60)) do
      {:ok, output} -> Jason.decode(output)
      {:error, reason} -> {:error, Shell.describe(reason)}
    end
  end
end
