defmodule Factory.Workspace.Git do
  @moduledoc """
  Keeps clones under `~/.software-factory` (or `FACTORY_HOME`), away from the
  developer's own checkouts.
  """
  @behaviour Factory.Workspace
  alias Factory.{Shell, Workspace}

  def home, do: System.get_env("FACTORY_HOME") || Path.expand("~/.software-factory")

  defp slug(project), do: String.replace(project.repo, "/", "__")
  defp repo_dir(project), do: Path.join([home(), "repos", slug(project)])

  def worktree_dir(project, issue),
    do: Path.join([home(), "worktrees", slug(project), "issue-#{issue.number}"])

  @impl true
  def prepare(project, issue) do
    repo = repo_dir(project)
    path = worktree_dir(project, issue)

    with :ok <- ensure_clone(project, repo),
         {:ok, _} <- git(repo, ~w(fetch origin --prune)),
         :ok <- ensure_worktree(repo, path, project, issue) do
      {:ok, path}
    else
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp ensure_clone(project, repo) do
    if File.dir?(Path.join(repo, ".git")) do
      :ok
    else
      File.mkdir_p!(Path.dirname(repo))

      with {:ok, _} <-
             Shell.run("gh", ["repo", "clone", project.repo, repo], timeout: :timer.minutes(10)) do
        :ok
      end
    end
  end

  defp ensure_worktree(repo, path, project, issue) do
    if File.dir?(path) do
      :ok
    else
      File.mkdir_p!(Path.dirname(path))
      git(repo, ~w(worktree prune))

      # Continue from the pushed branch when there is one, e.g. after the worktree was removed.
      start =
        case git(repo, ~w(rev-parse --verify --quiet origin/#{issue.branch})) do
          {:ok, _} -> "origin/#{issue.branch}"
          _ -> "origin/#{project.base_branch}"
        end

      with {:ok, _} <- git(repo, ["worktree", "add", "-B", issue.branch, path, start]), do: :ok
    end
  end

  @impl true
  def plan_ready?(path, issue) do
    Enum.all?(
      Workspace.plan_files(),
      &File.regular?(Path.join([path, Workspace.plan_dir(issue), &1]))
    )
  end

  @impl true
  def commit(path, message, opts \\ []) do
    add = if only = opts[:only], do: ["add", "-A", "--", only], else: ~w(add -A)

    with {:ok, _} <- git(path, add),
         :ok <- commit_staged(path, message) do
      # With `only`, whatever else was touched is not part of this step: drop it.
      if opts[:only] do
        git(path, ~w(checkout -- .))
        git(path, ~w(clean -fd))
      end

      :ok
    else
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp commit_staged(path, message) do
    case git(path, ~w(diff --cached --quiet)) do
      {:ok, _} -> :ok
      {:error, {:exit, 1, _}} -> with({:ok, _} <- git(path, ["commit", "-m", message]), do: :ok)
      error -> error
    end
  end

  @impl true
  def code_changed?(path, project) do
    args = [
      "diff",
      "--quiet",
      "origin/#{project.base_branch}...HEAD",
      "--",
      ".",
      ":(exclude).factory"
    ]

    match?({:error, {:exit, 1, _}}, git(path, args))
  end

  @impl true
  def push(path, issue) do
    case git(path, ~w(push -u origin #{issue.branch})) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  @doc """
  The commits a push would send are those reachable from `HEAD` but not from
  `origin/<base>` nor, once pushed, `origin/<branch>`. Their messages and the
  lines they add are returned as blocks; a two-parent merge adds what differs
  from the automatic merge of its parents (`--remerge-diff`, git >= 2.36).

  The patch is asked for so that nothing the repository configures can hide or
  transform its content: no textconv, no external diff, binary files as text.
  A merge git cannot diff that way (three or more parents) is an error.
  """
  @impl true
  def unpushed_changes(path, project, issue) do
    range = ["HEAD", "--not", "origin/#{project.base_branch}"] ++ pushed_branch(path, issue)

    patch_args =
      ~w(log -p --no-color --no-ext-diff --no-textconv --text --no-renames
         --diff-merges=remerge --format=tformat:factory-commit) ++ range

    with {:ok, messages} <- git(path, ["log", "-z", "--format=%B" | range]),
         {:ok, octopus} <- git(path, ["rev-list", "--min-parents=3" | range]),
         :ok <- no_octopus(octopus),
         {:ok, patch} <- git(path, patch_args),
         :ok <- no_diff_warning(patch) do
      messages = messages |> String.split(<<0>>) |> Enum.reject(&(String.trim(&1) == ""))
      {:ok, messages ++ added_blocks(patch)}
    else
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp pushed_branch(path, issue) do
    case git(path, ~w(rev-parse --verify --quiet origin/#{issue.branch})) do
      {:ok, _} -> ["origin/#{issue.branch}"]
      _ -> []
    end
  end

  defp no_octopus(output) do
    case String.split(output, "\n", trim: true) do
      [] ->
        :ok

      shas ->
        {:error,
         "the octopus merge #{Enum.join(shas, ", ")} cannot be checked for secrets: " <>
           "merge one branch at a time"}
    end
  end

  # git writes this when it could not diff a commit, which then has no patch to check.
  defp no_diff_warning(patch) do
    case Enum.find(String.split(patch, "\n"), &String.starts_with?(&1, "diff: warning:")) do
      nil -> :ok
      line -> {:error, "the commits to push cannot be checked for secrets: #{line}"}
    end
  end

  @doc false
  # Each run of consecutive added lines of a hunk, without the `+` and with a
  # `\n` after each line. Headers (`+++ b/…` included) are never content.
  def added_blocks(patch) do
    {blocks, current, _mode} =
      patch
      |> String.split("\n")
      |> Enum.reduce({[], [], :header}, fn line, {blocks, current, mode} ->
        cond do
          String.starts_with?(line, "@@") ->
            {close(blocks, current), [], :hunk}

          mode == :header ->
            {blocks, current, :header}

          String.starts_with?(line, "+") ->
            added = line |> binary_part(1, byte_size(line) - 1) |> String.trim_trailing("\r")
            {blocks, [current, added, "\n"], :hunk}

          # Context (an empty line is blank context with `diff.suppressBlankEmpty`),
          # a removed line or `\ No newline at end of file` end the run.
          line == "" or String.starts_with?(line, [" ", "-", "\\"]) ->
            {close(blocks, current), [], :hunk}

          true ->
            {close(blocks, current), [], :header}
        end
      end)

    blocks |> close(current) |> Enum.reverse()
  end

  defp close(blocks, current) do
    case IO.iodata_to_binary(current) do
      "" -> blocks
      block -> [block | blocks]
    end
  end

  @impl true
  def cleanup(project, issue) do
    git(repo_dir(project), ["worktree", "remove", "--force", worktree_dir(project, issue)])
    :ok
  end

  @doc """
  The committed plan files, read from the issue's branch rather than its
  worktree, so they stay readable after the worktree is removed.
  """
  @impl true
  def read_plan(_project, %{branch: nil}), do: []

  def read_plan(project, issue) do
    repo = repo_dir(project)

    ref =
      File.dir?(repo) &&
        Enum.find(
          ["refs/heads/#{issue.branch}", "refs/remotes/origin/#{issue.branch}"],
          &match?({:ok, _}, git(repo, ["rev-parse", "--verify", "--quiet", &1]))
        )

    for file <- Workspace.plan_files(),
        ref,
        {:ok, content} <- [git(repo, ["show", "#{ref}:#{Workspace.plan_dir(issue)}/#{file}"])],
        do: %{name: file, content: content}
  end

  defp git(dir, args), do: Shell.run("git", args, cd: dir, timeout: :timer.minutes(5))

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: Shell.describe(reason)
end
