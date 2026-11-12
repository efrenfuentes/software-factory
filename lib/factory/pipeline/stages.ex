defmodule Factory.Pipeline.Stages do
  @moduledoc """
  What happens in each active state, and which state follows.

  The agents only produce a result; every decision about where the issue goes
  next — including counting review rounds and stopping for a person — is made
  here, in plain code.
  """
  alias Factory.{Agents, Gates, GitHub, Pipeline, Stacks, Workspace}
  alias Factory.Agents.Prompts
  alias Factory.Pipeline.Issue
  alias Factory.Projects.Project

  @needs_human "factory:needs-human"
  # Developer runs per visit to `developing`; the last one uses the next model tier up.
  @max_attempts 3

  def needs_human_label, do: @needs_human

  @spec run(Issue.t()) :: {:ok, Issue.t()}
  def run(%Issue{} = issue) do
    issue = Factory.Repo.preload(issue, :project)
    project = issue.project
    GitHub.impl().set_label(project.repo, issue.number, @needs_human, false)

    result =
      try do
        step(issue.state, issue, project)
      rescue
        exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
      end

    case result do
      {:ok, %Issue{} = issue} ->
        if Issue.waiting?(issue),
          do: GitHub.impl().set_label(project.repo, issue.number, @needs_human, true)

        {:ok, issue}

      {:error, reason} ->
        GitHub.impl().set_label(project.repo, issue.number, @needs_human, true)
        Pipeline.fail(issue, if(is_binary(reason), do: reason, else: inspect(reason)))
    end
  end

  ## Planning

  defp step("planning", issue, project) do
    with {:ok, gh_issue} <- open_issue(project, issue),
         {:ok, path} <- Workspace.impl().prepare(project, issue),
         {:ok, plan} <-
           Agents.run(issue, project, %{
             role: :planner,
             stage: "planning",
             round: issue.plan_round,
             cwd: path,
             schema: Prompts.planner_schema(),
             prompt:
               Prompts.planner(
                 issue,
                 gh_issue,
                 Project.allowed_logins(project),
                 changes_requested(issue, "plan_review")
               )
           }) do
      planned(issue, project, path, plan)
    else
      :closed -> Pipeline.cancel(issue, "The issue was closed")
      error -> error
    end
  end

  defp step("plan_review", issue, project) do
    with {:ok, gh_issue} <- open_issue(project, issue),
         {:ok, path} <- Workspace.impl().prepare(project, issue),
         {:ok, review} <-
           Agents.run(issue, project, %{
             role: :reviewer,
             stage: "plan_review",
             round: issue.plan_round + 1,
             cwd: path,
             schema: Prompts.review_schema(),
             prompt: Prompts.plan_reviewer(issue, gh_issue, Project.allowed_logins(project))
           }) do
      issue = Pipeline.update_issue(issue, %{plan_round: issue.plan_round + 1})

      cond do
        approved?(review) ->
          plan_approved(issue, project)

        issue.plan_round >= issue.plan_round_limit ->
          GitHub.post(project.repo, issue.number, """
          **Plan review: changes still requested after #{issue.plan_round} round(s).** A person needs to decide.

          #{Prompts.findings(review)}

          Reply `/factory approve` to allow one more revision round, or `/factory stop` to stop.
          """)

          Pipeline.hold(issue, "plan_rounds_exhausted", review["summary"], "planning")

        true ->
          Pipeline.transition(
            issue,
            "planning",
            %{},
            "Plan review round #{issue.plan_round}: changes requested"
          )
      end
    else
      :closed -> Pipeline.cancel(issue, "The issue was closed")
      error -> error
    end
  end

  ## Development

  defp step("developing", issue, project) do
    with {:ok, path} <- Workspace.impl().prepare(project, issue),
         :ok <- setup(project, issue, path) do
      commands = Stacks.commands(project, path)

      context = %{
        review: issue.pr_number && changes_requested(issue, "pr_review"),
        gate_failure: nil,
        checks: for(c <- [commands.test, commands.lint], c, do: "- `#{c}`") |> Enum.join("\n")
      }

      develop(issue, project, path, context, 1)
    end
  end

  defp step("pr_review", issue, project) do
    with {:ok, path} <- Workspace.impl().prepare(project, issue),
         {:ok, review} <-
           Agents.run(issue, project, %{
             role: :reviewer,
             stage: "pr_review",
             round: issue.pr_round + 1,
             cwd: path,
             schema: Prompts.review_schema(),
             prompt: Prompts.pr_reviewer(issue, project.base_branch)
           }) do
      issue = Pipeline.update_issue(issue, %{pr_round: issue.pr_round + 1})
      approved? = approved?(review)
      exhausted? = issue.pr_round >= issue.pr_round_limit

      GitHub.post(project.repo, issue.pr_number, """
      **Review round #{issue.pr_round}: #{if approved?, do: "approved", else: "changes requested"}**

      #{Prompts.findings(review)}
      #{if not approved? and exhausted?, do: "\nThis was the last automatic round. Comment `/factory approve` to allow one more, or `/factory stop` to stop.", else: ""}
      """)

      cond do
        approved? ->
          GitHub.post(
            project.repo,
            issue.number,
            "The pull request #{issue.pr_url} passed review and is ready for a person to merge."
          )

          Pipeline.transition(
            issue,
            "ready_to_merge",
            %{},
            "Approved in review round #{issue.pr_round}"
          )

        exhausted? ->
          Pipeline.hold(issue, "pr_rounds_exhausted", review["summary"], "developing")

        true ->
          Pipeline.transition(
            issue,
            "developing",
            %{},
            "PR review round #{issue.pr_round}: changes requested"
          )
      end
    end
  end

  defp step(state, _issue, _project), do: {:error, "no stage for state #{state}"}

  ## Planning helpers

  defp planned(issue, project, _path, %{
         "status" => "questions",
         "questions" => [_ | _] = questions
       }) do
    list = questions |> Enum.with_index(1) |> Enum.map_join("\n", fn {q, i} -> "#{i}. #{q}" end)

    with :ok <-
           GitHub.post(project.repo, issue.number, """
           **The Planner needs some answers before writing the plan:**

           #{list}

           Answer in a comment; planning continues once you do.
           """) do
      Pipeline.transition(
        issue,
        "awaiting_answers",
        %{},
        "#{length(questions)} question(s) asked"
      )
    end
  end

  defp planned(issue, project, path, plan) do
    ws = Workspace.impl()

    with true <-
           ws.plan_ready?(path, issue) ||
             {:error, "the planner did not write spec.md, plan.md and tasks.md"},
         :ok <- ws.commit(path, "Plan for ##{issue.number}", only: Workspace.plan_dir(issue)),
         :ok <- ws.push(path, issue) do
      issue = Pipeline.update_issue(issue, %{difficulty: plan["difficulty"]})

      if issue.plan_round_limit == 0 do
        plan_approved(issue, project)
      else
        Pipeline.transition(
          issue,
          "plan_review",
          %{},
          "Plan written — difficulty: #{issue.difficulty}"
        )
      end
    end
  end

  defp plan_approved(issue, project) do
    plan = Pipeline.last_run(issue, "planning")

    wait? =
      project.plan_approval == "always" or
        (project.plan_approval == "hard" and issue.difficulty == "hard")

    {model, effort} = Project.model_for(project, {:developer, issue.difficulty})

    GitHub.post(project.repo, issue.number, """
    **Plan ready** — difficulty: **#{issue.difficulty}** (#{plan && plan.output["difficulty_reason"]})

    #{plan && plan.summary}

    Spec, plan and tasks: https://github.com/#{project.repo}/tree/#{issue.branch}/#{Workspace.plan_dir(issue)}

    #{if wait?, do: "Reply `/factory approve` to start development, or comment with what should change.", else: "Development starts now with #{model} (#{effort})."}
    """)

    if wait? do
      Pipeline.transition(issue, "awaiting_plan_approval", %{}, "Plan approved by the Reviewer")
    else
      Pipeline.transition(issue, "developing", %{}, "Plan approved")
    end
  end

  ## Development helpers

  defp setup(project, issue, path) do
    with {:error, output} <- Gates.impl().setup(project, issue, path) do
      {:error, "Setup failed. #{output}"}
    end
  end

  defp develop(issue, project, path, context, attempt) do
    tier = if attempt == @max_attempts, do: escalate(issue.difficulty), else: issue.difficulty

    spec = %{
      role: :developer,
      tier: tier,
      stage: "developing",
      round: issue.pr_round,
      cwd: path,
      schema: Prompts.developer_schema(),
      prompt: Prompts.developer(issue, context)
    }

    with {:ok, work} <- Agents.run(issue, project, spec) do
      if work["status"] == "blocked" do
        reason = work["blocked_reason"] || work["summary"]

        GitHub.post(
          project.repo,
          issue.number,
          "**The Developer is blocked:** #{reason}\n\nReply `/factory approve` to try again once it is resolved."
        )

        Pipeline.hold(issue, "developer_blocked", reason, "developing")
      else
        with :ok <- Workspace.impl().commit(path, "Work on ##{issue.number}", []) do
          gates(issue, project, path, context, attempt, work)
        end
      end
    end
  end

  defp gates(issue, project, path, context, attempt, work) do
    run = Pipeline.start_run(issue, %{stage: "gates", role: "gates", round: attempt})

    case Gates.impl().check(project, issue, path) do
      :ok ->
        Pipeline.finish_run(run, "ok", %{summary: "Tests and lint pass"})
        deliver(issue, project, path, work)

      {:error, output} ->
        Pipeline.finish_run(run, "failed", %{summary: output})

        if attempt < @max_attempts do
          develop(issue, project, path, %{context | gate_failure: output}, attempt + 1)
        else
          GitHub.post(
            project.repo,
            issue.number,
            "**The checks still fail after #{attempt} attempts.** Reply `/factory approve` to try again.\n\n```\n#{Factory.Shell.tail(output, 3000)}\n```"
          )

          Pipeline.hold(issue, "gates_failed", output, "developing")
        end
    end
  end

  defp deliver(issue, project, path, work) do
    ws = Workspace.impl()

    cond do
      not ws.code_changed?(path, project) ->
        Pipeline.hold(
          issue,
          "no_changes",
          "The Developer finished without changing any code.",
          "developing"
        )

      issue.pr_number ->
        with :ok <- ws.push(path, issue) do
          GitHub.post(
            project.repo,
            issue.pr_number,
            "**Changes pushed for review round #{issue.pr_round + 1}.**\n\n#{work["summary"]}"
          )

          Pipeline.transition(issue, "pr_review", %{}, "Review changes pushed")
        end

      true ->
        body =
          GitHub.sign("""
          #{work["summary"]}

          Spec, plan and tasks are in `#{Workspace.plan_dir(issue)}/`.

          Closes ##{issue.number}
          """)

        with :ok <- ws.push(path, issue),
             {:ok, pr} <-
               GitHub.impl().create_pr(project.repo, %{
                 head: issue.branch,
                 base: project.base_branch,
                 title: issue.title,
                 body: body
               }) do
          Pipeline.transition(
            issue,
            "pr_review",
            %{pr_number: pr.number, pr_url: pr.url},
            "Pull request ##{pr.number} opened"
          )
        end
    end
  end

  # An approval that still lists blocking problems is not one.
  defp approved?(review), do: review["verdict"] == "approve" and review["blocking"] in [nil, []]

  defp escalate("easy"), do: "medium"
  defp escalate(_), do: "hard"

  ## Shared

  defp open_issue(project, issue) do
    case GitHub.impl().get_issue(project.repo, issue.number) do
      {:ok, %{state: "CLOSED"}} -> :closed
      other -> other
    end
  end

  # The findings of the last review of `stage`, when it asked for changes.
  defp changes_requested(issue, stage) do
    case Pipeline.last_run(issue, stage) do
      %{output: %{"verdict" => "changes_requested"} = review} -> review
      _ -> nil
    end
  end
end
