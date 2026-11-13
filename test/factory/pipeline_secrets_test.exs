defmodule Factory.PipelineSecretsTest do
  # Changes the application's configuration (the secrets key).
  use Factory.DataCase, async: false

  alias Factory.{Fakes, Pipeline, Projects, Secrets}
  alias Factory.Pipeline.{Issue, Stages}

  @value "s3cr3t-value-123"
  @check_only "check-only-value-9"

  setup do
    key = Application.get_env(:factory, :secrets_key)
    on_exit(fn -> Application.put_env(:factory, :secrets_key, key) end)

    Fakes.State.reset()
    Fakes.GitHub.put_issue(7, title: "Add export")

    {:ok, project} =
      Projects.create_project(%{
        repo: "acme/app",
        app_type: "elixir",
        allowed_users: "maintainer"
      })

    %{project: project, user: Factory.AccountsFixtures.user_fixture(), key: key}
  end

  defp add_secret(project, user, name, value, checks_only \\ false) do
    {:ok, _} =
      Secrets.create_secret(
        project,
        %{"name" => name, "value" => value, "checks_only" => checks_only},
        user
      )
  end

  defp track(project) do
    {:ok, issue} =
      Pipeline.track_issue(project, %{number: 7, title: "Add export", body: "Body", url: "u"})

    issue
  end

  defp drive(issue, guard \\ 30) do
    issue = Pipeline.get_issue!(issue.id)

    if Issue.active?(issue) and guard > 0 do
      {:ok, issue} = Stages.run(issue)
      drive(issue, guard - 1)
    else
      issue
    end
  end

  defp requests(role), do: Enum.filter(Fakes.Agent.requests(), &(&1.role == role))
  defp runs(issue, stage), do: issue |> Pipeline.list_runs() |> Enum.filter(&(&1.stage == stage))
  defp posted_bodies, do: Enum.map(Fakes.GitHub.posted(), &elem(&1, 1))
  defp pr, do: Fakes.State.get(:prs)[100]

  describe "loading the secrets (RF-19)" do
    test "a project whose secrets cannot be decrypted fails before anything starts", %{
      project: project,
      user: user,
      key: key
    } do
      add_secret(project, user, "API_KEY", @value)
      Application.put_env(:factory, :secrets_key, nil)

      issue = project |> track() |> drive()

      assert issue.state == "failed"
      assert issue.hold_detail =~ "API_KEY"
      refute issue.hold_detail =~ @value
      assert Pipeline.list_runs(issue) == []
      assert Fakes.Agent.requests() == []
      assert Fakes.Gates.setups() == 0
      assert Fakes.Workspace.pushes() == []

      Application.put_env(:factory, :secrets_key, Base.encode64(:binary.copy("o", 32)))
      assert %{state: "failed"} = drive(elem(Pipeline.approve(issue), 1))

      Application.put_env(:factory, :secrets_key, key)
      {:ok, issue} = Pipeline.approve(Pipeline.get_issue!(issue.id))
      assert %{state: "ready_to_merge"} = drive(issue)
      assert Secrets.Current.get() == nil
    end

    test "a project without secrets runs as before without a key", %{project: project} do
      Application.put_env(:factory, :secrets_key, nil)
      assert %{state: "ready_to_merge"} = project |> track() |> drive()
      assert Secrets.Current.get() == nil
    end
  end

  describe "the setup (RF-16)" do
    test "runs with its own stage run before the Developer", %{project: project} do
      issue = project |> track() |> drive()

      assert issue.state == "ready_to_merge"
      runs = Pipeline.list_runs(issue)
      setup = Enum.find_index(runs, &(&1.stage == "setup"))
      developer = Enum.find_index(runs, &(&1.role == "developer"))
      assert setup < developer
      assert %{status: "ok", role: "setup"} = Enum.at(runs, setup)
      assert Fakes.Gates.setups() == 1
    end

    test "does not start once the issue is cancelled after prepare", %{project: project} do
      {:ok, project} = Projects.update_project(project, %{plan_approval: "always"})
      issue = project |> track() |> drive()
      assert issue.state == "awaiting_plan_approval"

      Fakes.Workspace.during_prepare(fn -> Pipeline.cancel(issue) end)
      {:ok, issue} = Pipeline.approve(issue)
      issue = drive(issue)

      assert issue.state == "cancelled"
      assert Fakes.Gates.setups() == 0
      assert runs(issue, "setup") == []
      assert requests(:developer) == []
    end
  end

  describe "the environment of the agents (RF-17/18)" do
    test "only the Developer gets secrets, never those only for the checks", %{
      project: project,
      user: user
    } do
      add_secret(project, user, "API_KEY", @value)
      add_secret(project, user, "CHECK_ONLY", @check_only, true)

      assert %{state: "ready_to_merge"} = project |> track() |> drive()

      [developer] = requests(:developer)
      assert developer.env == [{"API_KEY", @value}]
      assert developer.prompt =~ "`API_KEY`"
      assert developer.prompt =~ "`CHECK_ONLY`"
      refute developer.prompt =~ @value
      refute developer.prompt =~ @check_only

      for request <- requests(:planner) ++ requests(:reviewer), do: assert(request.env == [])
    end
  end

  describe "the filter of what the factory stores and publishes (RF-20/21)" do
    test "check output is filtered everywhere it goes", %{project: project, user: user} do
      add_secret(project, user, "API_KEY", @value)
      Fakes.Gates.script([{:error, "token=#{@value}"}])

      issue = project |> track() |> drive()

      assert %{state: "needs_human", hold_reason: "gates_failed"} = issue
      assert issue.hold_detail =~ "[SECRET:API_KEY]"
      refute issue.hold_detail =~ @value

      for run <- runs(issue, "gates") do
        assert run.summary =~ "[SECRET:API_KEY]"
        refute run.summary =~ @value
      end

      assert Enum.any?(posted_bodies(), &(&1 =~ "[SECRET:API_KEY]"))
      refute Enum.any?(posted_bodies(), &(&1 =~ @value))

      [_first, second | _] = requests(:developer)
      assert second.prompt =~ "[SECRET:API_KEY]"
      refute second.prompt =~ @value

      for t <- Pipeline.list_transitions(issue), t.note, do: refute(t.note =~ @value)
    end

    test "an agent's answer is filtered in its run, comments and pull request", %{
      project: project,
      user: user
    } do
      add_secret(project, user, "API_KEY", @value)
      Fakes.Agent.script(:developer, [%{"status" => "done", "summary" => "used #{@value}"}])

      issue = project |> track() |> drive()
      assert issue.state == "ready_to_merge"

      [run] = Enum.filter(Pipeline.list_runs(issue), &(&1.role == "developer"))
      assert run.summary == "used [SECRET:API_KEY]"
      assert run.output["summary"] == "used [SECRET:API_KEY]"
      assert pr().body =~ "used [SECRET:API_KEY]"
      refute pr().body =~ @value
      refute Enum.any?(posted_bodies(), &(&1 =~ @value))
    end

    test "an agent's error and an exception are filtered in the failure", %{
      project: project,
      user: user
    } do
      add_secret(project, user, "API_KEY", @value)
      Fakes.Agent.script(:planner, [{:error, "boom #{@value}"}])

      issue = project |> track() |> drive()
      assert issue.state == "failed"
      assert issue.hold_detail =~ "boom [SECRET:API_KEY]"
      refute issue.hold_detail =~ @value
      [run] = runs(issue, "planning")
      refute run.summary =~ @value

      Fakes.Agent.script(:planner, [])
      Fakes.Agent.during(:planner, fn -> raise "exploded with #{@value}" end)
      {:ok, issue} = Pipeline.approve(issue)
      issue = drive(issue)

      assert issue.state == "failed"
      assert issue.hold_detail =~ "exploded with [SECRET:API_KEY]"
      refute issue.hold_detail =~ @value
    end

    test "a value at the edge of a cut git error leaves no piece behind", %{
      project: project,
      user: user
    } do
      add_secret(project, user, "API_KEY", @value)
      Fakes.Workspace.fail_push(@value <> String.duplicate("x", 5996))

      issue = project |> track() |> drive()
      piece = String.slice(@value, -4, 4)

      assert issue.state == "failed"
      refute issue.hold_detail =~ piece
      for t <- Pipeline.list_transitions(issue), t.note, do: refute(t.note =~ piece)
    end
  end

  describe "the push check (RF-22/23/24)" do
    test "the plan is not pushed while its commits contain a value", %{
      project: project,
      user: user
    } do
      add_secret(project, user, "API_KEY", @value)
      Fakes.Workspace.set_unpushed(["msg\n", "x = #{@value}\n"])

      issue = project |> track() |> drive()

      assert %{state: "needs_human", hold_reason: "secret_in_diff", resume_state: "planning"} =
               issue

      assert Fakes.Workspace.pushes() == []
      assert Enum.any?(posted_bodies(), &(&1 =~ "`API_KEY`"))
      refute Enum.any?(posted_bodies(), &(&1 =~ @value))
      assert FactoryWeb.Format.hold("secret_in_diff") =~ "value of a project secret"
    end

    test "the code is not pushed until the Developer removes the value", %{
      project: project,
      user: user
    } do
      add_secret(project, user, "API_KEY", @value)
      Fakes.Agent.during(:developer, fn -> Fakes.Workspace.set_unpushed(["#{@value}\n"]) end)

      issue = project |> track() |> drive()

      assert %{state: "needs_human", hold_reason: "secret_in_diff", resume_state: "developing"} =
               issue

      assert Fakes.Workspace.pushes() == [7]
      assert pr() == nil

      Fakes.Agent.during(:developer, fn -> Fakes.Workspace.set_unpushed([]) end)
      {:ok, issue} = Pipeline.approve(issue)
      issue = drive(issue)

      assert issue.state == "ready_to_merge"
      [first, second] = requests(:developer)
      refute first.prompt =~ "refused to push"
      assert second.prompt =~ "refused to push"
      assert second.prompt =~ "`API_KEY`"
      refute second.prompt =~ @value
      assert Fakes.Workspace.pushes() == [7, 7]
      assert pr()
    end

    test "a multiline value only blocks when it is whole in one block", %{
      project: project,
      user: user
    } do
      add_secret(project, user, "SHORT_LINES", "abcd\nefgh")
      Fakes.Workspace.set_unpushed(["abcd\n", "efgh\n"])
      assert %{state: "ready_to_merge"} = project |> track() |> drive()

      Fakes.State.reset()
      Fakes.GitHub.put_issue(8, title: "Other")
      Fakes.Workspace.set_unpushed(["abcd\nefgh\n"])

      {:ok, issue} =
        Pipeline.track_issue(project, %{number: 8, title: "Other", body: "Body", url: "u"})

      assert %{state: "needs_human", hold_reason: "secret_in_diff"} = drive(issue)
    end

    test "a project without secrets pushes whatever the commits hold", %{project: project} do
      Fakes.Workspace.set_unpushed(["#{@value}\n"])
      assert %{state: "ready_to_merge"} = project |> track() |> drive()
    end

    test "when what the push would send cannot be read, nothing is pushed", %{
      project: project,
      user: user
    } do
      add_secret(project, user, "API_KEY", @value)
      Fakes.Workspace.set_unpushed({:error, "octopus merge abc cannot be checked for secrets"})

      issue = project |> track() |> drive()
      assert issue.state == "failed"
      assert issue.hold_detail =~ "octopus merge abc"
      assert Fakes.Workspace.pushes() == []
      assert pr() == nil
    end

    test "the commit checked for secrets is the one pushed", %{project: project, user: user} do
      add_secret(project, user, "API_KEY", @value)
      Fakes.Workspace.set_head({:ok, "plan-sha"})
      Fakes.Agent.during(:developer, fn -> Fakes.Workspace.set_head({:ok, "code-sha"}) end)

      assert %{state: "ready_to_merge"} = project |> track() |> drive()
      assert Fakes.Workspace.pushed_shas() == [{7, "plan-sha"}, {7, "code-sha"}]
      assert "plan-sha" in Fakes.Workspace.checked_shas()
      assert "code-sha" in Fakes.Workspace.checked_shas()
      refute Enum.any?(Fakes.Workspace.checked_shas(), &(&1 not in ["plan-sha", "code-sha"]))
    end

    test "a worktree that is not on the issue's branch is never pushed", %{
      project: project,
      user: user
    } do
      add_secret(project, user, "API_KEY", @value)

      Fakes.Agent.during(:developer, fn ->
        Fakes.Workspace.set_head({:error, "the worktree is on refs/heads/innocent"})
      end)

      issue = project |> track() |> drive()
      assert issue.state == "failed"
      assert issue.hold_detail =~ "refs/heads/innocent"
      assert Fakes.Workspace.pushes() == [7]
      assert pr() == nil
    end

    test "nor when that happens on the push of the code", %{project: project, user: user} do
      add_secret(project, user, "API_KEY", @value)

      Fakes.Agent.during(:developer, fn ->
        Fakes.Workspace.set_unpushed({:error, "octopus merge abc cannot be checked for secrets"})
      end)

      issue = project |> track() |> drive()
      assert issue.state == "failed"
      assert issue.hold_detail =~ "octopus merge abc"
      assert Fakes.Workspace.pushes() == [7]
      assert pr() == nil
    end
  end
end
