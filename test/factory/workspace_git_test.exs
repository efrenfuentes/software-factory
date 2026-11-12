defmodule Factory.Workspace.GitTest do
  use ExUnit.Case, async: false

  alias Factory.Pipeline.Issue
  alias Factory.Projects.Project
  alias Factory.Workspace.Git

  @project %Project{repo: "acme/app", base_branch: "main"}
  @issue %Issue{number: 7, branch: "factory/issue-7"}

  setup do
    home = Path.join(System.tmp_dir!(), "factory-home-#{System.unique_integer([:positive])}")
    origin = Path.join(home, "origin.git")
    clone = Path.join([home, "repos", "acme__app"])
    File.mkdir_p!(Path.dirname(clone))

    git!(home, ~w(init --quiet --bare --initial-branch=main #{origin}))
    git!(home, ~w(clone --quiet #{origin} #{clone}))
    git!(clone, ~w(config user.email factory@example.com))
    git!(clone, ~w(config user.name Factory))
    File.write!(Path.join(clone, "README.md"), "app\n")
    git!(clone, ~w(add -A))
    git!(clone, ~w(commit --quiet -m init))
    git!(clone, ~w(push --quiet origin HEAD:main))

    System.put_env("FACTORY_HOME", home)

    on_exit(fn ->
      System.delete_env("FACTORY_HOME")
      File.rm_rf!(home)
    end)

    %{origin: origin}
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end

  test "plans and code go to the issue's branch, and work resumes from what was pushed", %{
    origin: origin
  } do
    assert {:ok, path} = Git.prepare(@project, @issue)
    assert git!(path, ~w(branch --show-current)) == "factory/issue-7\n"
    refute Git.plan_ready?(path, @issue)

    plan = Path.join(path, ".factory/issue-7")
    File.mkdir_p!(plan)
    for file <- ~w(spec.md plan.md tasks.md), do: File.write!(Path.join(plan, file), "x")
    File.write!(Path.join(path, "stray.txt"), "the planner must not leave this")
    File.write!(Path.join(path, "README.md"), "edited by the planner\n")

    assert Git.plan_ready?(path, @issue)
    assert Git.read_plan(@project, @issue) == []
    assert :ok = Git.commit(path, "Plan for #7", only: ".factory/issue-7")

    assert [%{name: "spec.md", content: "x"}, %{name: "plan.md"}, %{name: "tasks.md"}] =
             Git.read_plan(@project, @issue)

    refute File.exists?(Path.join(path, "stray.txt"))
    assert File.read!(Path.join(path, "README.md")) == "app\n"
    refute Git.code_changed?(path, @project)

    # Nothing to commit is not an error.
    assert :ok = Git.commit(path, "Work on #7", [])

    File.write!(Path.join(path, "lib.ex"), "code")
    assert :ok = Git.commit(path, "Work on #7", [])
    assert Git.code_changed?(path, @project)

    assert :ok = Git.push(path, @issue)
    assert git!(origin, ~w(log --format=%s factory/issue-7)) == "Work on #7\nPlan for #7\ninit\n"

    assert :ok = Git.cleanup(@project, @issue)
    refute File.exists?(path)
    # The plan is read from the branch, so it outlives the worktree.
    assert [%{name: "spec.md"}, _, _] = Git.read_plan(@project, @issue)
    assert Git.read_plan(%Project{repo: "acme/never-cloned"}, @issue) == []
    assert {:ok, ^path} = Git.prepare(@project, @issue)
    assert File.exists?(Path.join(path, "lib.ex"))
  end
end
