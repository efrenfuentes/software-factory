defmodule Factory.Workspace.GitTest do
  use ExUnit.Case, async: false

  alias Factory.Pipeline.Issue
  alias Factory.Projects.Project
  alias Factory.Secrets
  alias Factory.Secrets.{Bundle, Current}
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

    %{origin: origin, clone: clone}
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end

  defp head!(path) do
    {:ok, sha} = Git.head(path, @issue)
    sha
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
    refute Git.code_changed?(path, @project, head!(path))

    # Nothing to commit is not an error.
    assert :ok = Git.commit(path, "Work on #7", [])

    File.write!(Path.join(path, "lib.ex"), "code")
    assert :ok = Git.commit(path, "Work on #7", [])
    assert Git.code_changed?(path, @project, head!(path))

    assert :ok = Git.push(path, @issue, head!(path))
    assert git!(origin, ~w(log --format=%s factory/issue-7)) == "Work on #7\nPlan for #7\ninit\n"

    assert :ok = Git.cleanup(@project, @issue)
    refute File.exists?(path)
    # The plan is read from the branch, so it outlives the worktree.
    assert [%{name: "spec.md"}, _, _] = Git.read_plan(@project, @issue)
    assert Git.read_plan(%Project{repo: "acme/never-cloned"}, @issue) == []
    assert {:ok, ^path} = Git.prepare(@project, @issue)
    assert File.exists?(Path.join(path, "lib.ex"))
  end

  describe "added_blocks/1" do
    test "only added lines of hunks are content, in runs of consecutive lines" do
      patch = """
      factory-commit
      diff --git a/f b/f
      --- a/f
      +++ b/f
      @@ -1,2 +1,4 @@
      ++x
      +abcd\r
      +efgh
       context
      +after
      -removed
      +again
      @@ -9 +9 @@
      +next
      \\ No newline at end of file
      +last
      diff --git a/g b/g
      +++ b/g
      @@ -1 +1 @@
      +other
      factory-commit
      @@ -1 +1 @@
      +commit2
      """

      assert Git.added_blocks(patch) == [
               "+x\nabcd\nefgh\n",
               "after\n",
               "again\n",
               "next\n",
               "last\n",
               "other\n",
               "commit2\n"
             ]
    end

    test "an empty line inside a hunk is blank context, and the hunk goes on" do
      patch = "factory-commit\n@@ -1,3 +1,4 @@\n a\n\n+x\n b\n"
      assert Git.added_blocks(patch) == ["x\n"]
    end

    test "headers never count, and separated runs never join" do
      patch = "factory-commit\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n+abcd\n@@ -5 +5 @@\n+efgh\n"
      assert Git.added_blocks(patch) == ["abcd\n", "efgh\n"]
    end
  end

  describe "unpushed_changes/4" do
    setup %{clone: clone, origin: origin} do
      {:ok, path} = Git.prepare(@project, @issue)
      on_exit(fn -> Current.delete() end)
      %{path: path, clone: clone, origin: origin}
    end

    defp commit!(dir, file, content, message) do
      File.mkdir_p!(Path.dirname(Path.join(dir, file)))
      File.write!(Path.join(dir, file), content)
      git!(dir, ~w(add -A))
      git!(dir, ["commit", "--quiet", "-m", message])
    end

    defp bundle(pairs) do
      Bundle.new(for {name, value} <- pairs, do: %{name: name, value: value, checks_only: false})
    end

    defp blocks(path) do
      assert {:ok, blocks} = Git.unpushed_changes(path, @project, @issue, head!(path))
      blocks
    end

    defp in_some?(blocks, text), do: Enum.any?(blocks, &String.contains?(&1, text))

    # Pushes a commit to origin/main from the factory's clone, and fetches it.
    defp push_to_main!(clone, path, file, content) do
      git!(clone, ~w(checkout --quiet main))
      git!(clone, ~w(pull --quiet origin main))
      commit!(clone, file, content, "main: #{file}")
      git!(clone, ~w(push --quiet origin HEAD:main))
      git!(path, ~w(fetch --quiet origin))
    end

    test "normal commits without secrets pass, and nothing is left once pushed", %{path: path} do
      commit!(path, "lib.ex", "code\n", "Work on #7")
      git!(path, ~w(commit --quiet --allow-empty -m empty))

      blocks = blocks(path)
      assert "code\n" in blocks
      assert Secrets.leaked(bundle([{"API_KEY", "not-there-123"}]), blocks) == []

      assert :ok = Git.push(path, @issue, head!(path))
      assert blocks(path) == []
    end

    test "a value added and removed, and one in a message, are found", %{path: path} do
      commit!(path, "a.txt", "X-added-value-1\n", "add")
      commit!(path, "a.txt", "clean\n", "remove")
      git!(path, ["commit", "--quiet", "--allow-empty", "-m", "uses Y-message-value-2"])

      blocks = blocks(path)
      assert in_some?(blocks, "X-added-value-1")
      assert in_some?(blocks, "Y-message-value-2")
    end

    test "a removed line or one already in the base is not", %{path: path, clone: clone} do
      push_to_main!(clone, path, "z.txt", "keep\nZ-removed-value-3\n")
      git!(path, ~w(merge --quiet --ff-only origin/main))
      commit!(path, "z.txt", "keep\n", "remove Z")

      refute in_some?(blocks(path), "Z-removed-value-3")
    end

    test "a multiline value is found whole only in consecutive added lines", %{path: path} do
      secret = bundle([{"SHORT_LINES", "abcd\nefgh"}])

      commit!(path, "m.txt", "abcd\nefgh\n", "together")
      assert in_some?(blocks(path), "abcd\nefgh\n")
      assert Secrets.leaked(secret, blocks(path)) == ["SHORT_LINES"]

      assert :ok = Git.push(path, @issue, head!(path))
      commit!(path, "one.txt", "abcd\n", "one")
      commit!(path, "two.txt", "efgh\n", "two")
      assert Secrets.leaked(secret, blocks(path)) == []

      File.write!(Path.join(path, "three.txt"), "abcd\n")
      File.write!(Path.join(path, "four.txt"), "efgh\n")
      git!(path, ~w(add -A))
      git!(path, ~w(commit --quiet -m two-files))
      assert Secrets.leaked(secret, blocks(path)) == []
    end

    test "a value written to resolve a merge conflict is found", %{path: path, clone: clone} do
      push_to_main!(clone, path, "c.txt", "base\n")
      git!(path, ~w(merge --quiet --ff-only origin/main))
      assert :ok = Git.push(path, @issue, head!(path))

      commit!(path, "c.txt", "branch\n", "branch change")
      push_to_main!(clone, path, "c.txt", "main\n")
      System.cmd("git", ~w(merge origin/main), cd: path, stderr_to_stdout: true)
      File.write!(Path.join(path, "c.txt"), "W-resolution-value\n")
      git!(path, ~w(add c.txt))
      git!(path, ~w(commit --quiet --no-edit))

      blocks = blocks(path)
      assert in_some?(blocks, "W-resolution-value")
      assert Secrets.leaked(bundle([{"W", "W-resolution-value"}]), blocks) == ["W"]
    end

    test "a value a merge only brings from the base is not", %{path: path, clone: clone} do
      commit!(path, "mine.txt", "mine\n", "branch work")
      push_to_main!(clone, path, "b.txt", "B-base-value-44\n")
      git!(path, ~w(merge --quiet --no-edit origin/main))

      refute in_some?(blocks(path), "B-base-value-44")
    end

    test "an octopus merge cannot be checked, until it is pushed", %{path: path} do
      for name <- ~w(b1 b2) do
        git!(path, ~w(checkout --quiet -b #{name} factory/issue-7))
        commit!(path, "#{name}.txt", "#{name}\n", name)
      end

      git!(path, ~w(checkout --quiet factory/issue-7))
      git!(path, ~w(merge --quiet --no-ff --no-commit b1 b2))
      File.write!(Path.join(path, "o.txt"), "O-octopus-value\n")
      git!(path, ~w(add o.txt))
      git!(path, ~w(commit --quiet -m octopus))
      sha = path |> git!(~w(rev-parse HEAD)) |> String.trim()

      assert {:error, message} = Git.unpushed_changes(path, @project, @issue, head!(path))
      assert message =~ sha
      refute message =~ "O-octopus-value"

      assert :ok = Git.push(path, @issue, head!(path))
      assert {:ok, []} = Git.unpushed_changes(path, @project, @issue, head!(path))
    end

    test "neither textconv nor -diff hide a value", %{path: path} do
      secret = bundle([{"HIDDEN", "SECRETVALUE123"}])
      File.write!(Path.join(path, ".gitattributes"), "s.txt diff=hide\nd.txt -diff\n")
      git!(path, ["config", "diff.hide.textconv", "sed s/SECRET/xxxxxx/"])
      commit!(path, "s.txt", "SECRETVALUE123\n", "textconv")

      blocks = blocks(path)
      assert in_some?(blocks, "SECRETVALUE123")
      refute in_some?(blocks, "xxxxxx")
      assert Secrets.leaked(secret, blocks) == ["HIDDEN"]

      assert :ok = Git.push(path, @issue, head!(path))
      commit!(path, "d.txt", "SECRETVALUE123\n", "binary")
      assert Secrets.leaked(secret, blocks(path)) == ["HIDDEN"]
    end

    test "messages are read whatever i18n.logOutputEncoding says, non-ASCII included", %{
      path: path
    } do
      secret = bundle([{"MSG", "project secrets in a message"}, {"ACCENT", "Ñandú-sécret-42"}])
      git!(path, ~w(config i18n.logOutputEncoding UTF-16LE))

      git!(path, ["commit", "--quiet", "--allow-empty", "-m", "uses project secrets in a message"])

      git!(path, ["commit", "--quiet", "--allow-empty", "-m", "contraseña: Ñandú-sécret-42"])

      assert Secrets.leaked(secret, blocks(path)) == ["ACCENT", "MSG"]
    end

    test "a message stored in another encoding is also read in UTF-8", %{path: path} do
      secret = bundle([{"LATIN", "contraseña-ñandú"}])
      file = Path.join(path, "../msg-latin1.txt")
      File.write!(file, :unicode.characters_to_binary("usa contraseña-ñandú", :utf8, :latin1))
      git!(path, ~w(-c i18n.commitEncoding=ISO-8859-1 commit --quiet --allow-empty -F #{file}))

      assert Secrets.leaked(secret, blocks(path)) == ["LATIN"]
    end

    test "a root commit merged from an unrelated history is diffed whatever log.showRoot says",
         %{path: path} do
      secret = bundle([{"ROOT", "R-root-secret-77"}])
      commit!(path, "mine.txt", "mine\n", "branch work")
      git!(path, ~w(checkout --quiet --orphan unrelated))
      git!(path, ~w(rm -rf --quiet .))
      commit!(path, "root.txt", "R-root-secret-77\n", "unrelated root")
      git!(path, ~w(checkout --quiet factory/issue-7))
      git!(path, ~w(merge --quiet --no-edit --allow-unrelated-histories unrelated))
      git!(path, ~w(config log.showRoot false))

      assert Secrets.leaked(secret, blocks(path)) == ["ROOT"]
    end

    test "a worktree on another branch than the issue's cannot be checked nor pushed", %{
      path: path,
      origin: origin
    } do
      commit!(path, "s.txt", "S-pending-secret-9\n", "secret on the issue's branch")
      git!(path, ~w(checkout --quiet -b innocent))
      commit!(path, "ok.txt", "fine\n", "innocent work")

      assert {:error, message} = Git.head(path, @issue)
      assert message =~ "refs/heads/innocent"
      assert message =~ "refs/heads/factory/issue-7"

      git!(path, ~w(checkout --quiet --detach))
      assert {:error, message} = Git.head(path, @issue)
      assert message =~ "detached HEAD"

      {_, status} = System.cmd("git", ~w(rev-parse --verify --quiet factory/issue-7), cd: origin)
      assert status != 0
    end

    test "the commit checked is the one pushed, even if the branch moves after", %{
      path: path,
      origin: origin
    } do
      commit!(path, "a.txt", "clean\n", "checked")
      sha = head!(path)
      assert Secrets.leaked(bundle([{"LATE", "L-late-secret-5"}]), blocks(path)) == []
      commit!(path, "b.txt", "L-late-secret-5\n", "added after the check")

      assert :ok = Git.push(path, @issue, sha)
      assert git!(origin, ~w(rev-parse factory/issue-7)) == sha <> "\n"

      assert git!(path, ~w(rev-parse --abbrev-ref factory/issue-7@{upstream})) ==
               "origin/factory/issue-7\n"
    end

    test "an added line after blank context is found with suppressBlankEmpty", %{
      path: path,
      clone: clone
    } do
      push_to_main!(clone, path, "blank.txt", "a\n\nb\n")
      git!(path, ~w(merge --quiet --ff-only origin/main))
      git!(path, ~w(config diff.suppressBlankEmpty true))
      commit!(path, "blank.txt", "a\n\nM-after-blank-1\nb\n", "after blank")

      assert in_some?(blocks(path), "M-after-blank-1")
    end
  end

  describe "git errors during a stage" do
    test "a pre-push hook that prints a secret leaves no piece of it", %{clone: clone} do
      {:ok, path} = Git.prepare(@project, @issue)
      on_exit(fn -> Current.delete() end)
      value = "Hook-secret-V4lu"
      hook = Path.join([clone, ".git", "hooks", "pre-push"])

      for filler <- [5996, 3000] do
        File.write!(hook, """
        #!/bin/sh
        printf '%s' '#{value}'
        head -c #{filler} /dev/zero | tr '\\0' x
        echo
        exit 1
        """)

        File.chmod!(hook, 0o755)
        Current.put(bundle([{"API_KEY", value}]))

        assert {:error, message} = Git.push(path, @issue, head!(path))
        refute message =~ String.slice(value, -4, 4)
        refute message =~ value
        # With the shorter filler, the whole value falls inside the cut: it is replaced.
        if filler == 3000, do: assert(message =~ "[SECRET:API_KEY]")
      end
    end
  end
end
