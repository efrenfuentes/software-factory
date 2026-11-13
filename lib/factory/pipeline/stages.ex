defmodule Factory.Pipeline.Stages do
  @moduledoc """
  What happens in each active state, and which state follows.

  The agents only produce a result; every decision about where the issue goes
  next — including counting review rounds and stopping for a person — is made
  here, in plain code.

  A person can stop the issue while a stage runs. Agents and checks only start
  if their run is recorded before that (`Pipeline.authorize_run/2`), and every
  effect outside the factory — a comment, the `needs_human` label, a commit, a
  push, a pull request — goes through `unless_stopped/2`, so nothing more
  happens once the issue is cancelled.

  The project's secrets are loaded once per stage, before anything starts; a
  project whose secrets cannot be decrypted fails without running anything.
  Every text the stage stores or publishes has their values replaced, and no
  push goes out while the commits it would send contain one.
  """
  alias Factory.{Agents, Gates, GitHub, Pipeline, Secrets, Stacks, Workspace}
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

    # Nothing starts — no agent, check, git command or run — without the secrets.
    case Secrets.load(project) do
      {:ok, bundle} ->
        Secrets.Current.put(bundle)

        try do
          run_stage(issue, %{project | secrets: bundle})
        after
          Secrets.Current.delete()
        end

      {:error, reason} ->
        outcome(issue, project, {:error, reason})
    end
  end

  defp run_stage(issue, project) do
    GitHub.impl().set_label(project.repo, issue.number, @needs_human, false)

    result =
      try do
        step(issue.state, issue, project)
      rescue
        exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
      end

    outcome(issue, project, result)
  end

  defp outcome(issue, project, result) do
    case result do
      {:stopped, %Issue{} = issue} ->
        {:ok, issue}

      {:ok, %Issue{} = issue} ->
        if Issue.waiting?(issue), do: label_needs_human(issue, project)
        {:ok, issue}

      {:error, reason} ->
        # An agent, the setup or a push failing after a cancellation is not a failure.
        if Pipeline.stopped?(issue) do
          {:ok, issue}
        else
          label_needs_human(issue, project)
          detail = if is_binary(reason), do: reason, else: inspect(reason)
          Pipeline.fail(issue, Secrets.redact(project.secrets, detail))
        end
    end
  end

  defp label_needs_human(issue, project) do
    unless_stopped(issue, fn ->
      GitHub.impl().set_label(project.repo, issue.number, @needs_human, true)
    end)
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
          post_then(
            issue,
            project,
            issue.number,
            """
            **Plan review: changes still requested after #{issue.plan_round} round(s).** A person needs to decide.

            #{Prompts.findings(review)}

            Reply `/factory approve` to allow one more revision round, or `/factory stop` to stop.
            """,
            fn -> hold(issue, project, "plan_rounds_exhausted", review["summary"], "planning") end
          )

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
        # What a maintainer asked for on the pull request, and what they asked before.
        feedback: issue.pr_feedback,
        decisions: issue.pr_decisions,
        gate_failure: nil,
        checks: for(c <- [commands.test, commands.lint], c, do: "- `#{c}`") |> Enum.join("\n"),
        secrets: Secrets.prompt_names(project.secrets),
        # Values left in the commits not pushed yet, e.g. after a push was refused for them;
        # if they cannot be read, the push asks again and fails.
        leaked_secrets:
          with {:ok, sha} <- Workspace.impl().head(path, issue),
               {:ok, names} <- leaked_secrets(issue, project, path, sha) do
            names
          else
            {:error, _} -> []
          end,
        base_branch: project.base_branch
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

      post_then(
        issue,
        project,
        issue.pr_number,
        """
        **Review round #{issue.pr_round}: #{if approved?, do: "approved", else: "changes requested"}**

        #{Prompts.findings(review)}
        #{if not approved? and exhausted?, do: "\nThis was the last automatic round. Comment `/factory approve` to allow one more, or `/factory stop` to stop.", else: ""}
        """,
        fn -> reviewed(issue, project, approved?, exhausted?, review) end
      )
    end
  end

  defp step(state, _issue, _project), do: {:error, "no stage for state #{state}"}

  defp reviewed(issue, project, true = _approved?, _exhausted?, _review) do
    post_then(
      issue,
      project,
      issue.number,
      "The pull request #{issue.pr_url} passed review and is ready for a person to merge.",
      fn ->
        # What a maintainer asked for is done: it stays as an agreed decision.
        Pipeline.transition(
          issue,
          "ready_to_merge",
          %{
            pr_feedback: nil,
            pr_decisions: Pipeline.join_feedback([issue.pr_decisions, issue.pr_feedback])
          },
          "Approved in review round #{issue.pr_round}"
        )
      end
    )
  end

  defp reviewed(issue, project, false, true = _exhausted?, review) do
    hold(issue, project, "pr_rounds_exhausted", review["summary"], "developing")
  end

  defp reviewed(issue, _project, false, false, _review) do
    Pipeline.transition(
      issue,
      "developing",
      %{},
      "PR review round #{issue.pr_round}: changes requested"
    )
  end

  ## Planning helpers

  defp planned(issue, project, _path, %{
         "status" => "questions",
         "questions" => [_ | _] = questions
       }) do
    list = questions |> Enum.with_index(1) |> Enum.map_join("\n", fn {q, i} -> "#{i}. #{q}" end)

    with :ok <-
           unless_stopped(issue, fn ->
             GitHub.post(
               project.repo,
               issue.number,
               Secrets.redact(project.secrets, """
               **The Planner needs some answers before writing the plan:**

               #{list}

               Answer in a comment; planning continues once you do.
               """)
             )
           end) do
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
         :ok <-
           unless_stopped(issue, fn ->
             ws.commit(path, "Plan for ##{issue.number}", only: Workspace.plan_dir(issue))
           end),
         {:ok, sha} <- ws.head(path, issue),
         :ok <- push(issue, project, path, sha) do
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

    post_then(
      issue,
      project,
      issue.number,
      """
      **Plan ready** — difficulty: **#{issue.difficulty}** (#{plan && plan.output["difficulty_reason"]})

      #{plan && plan.summary}

      Spec, plan and tasks: https://github.com/#{project.repo}/tree/#{issue.branch}/#{Workspace.plan_dir(issue)}

      #{if wait?, do: "Reply `/factory approve` to start development, or comment with what should change.", else: "Development starts now with #{model} (#{effort})."}
      """,
      fn ->
        if wait? do
          Pipeline.transition(
            issue,
            "awaiting_plan_approval",
            %{},
            "Plan approved by the Reviewer"
          )
        else
          Pipeline.transition(issue, "developing", %{}, "Plan approved")
        end
      end
    )
  end

  ## Development helpers

  # The setup gets the secrets, so it only starts once its run is recorded.
  defp setup(project, issue, path) do
    case Pipeline.authorize_run(issue, %{stage: "setup", role: "setup", round: issue.pr_round}) do
      {:error, :stopped} ->
        {:stopped, issue}

      {:ok, run} ->
        case Gates.impl().setup(project, issue, path) do
          :ok ->
            Pipeline.finish_run(run, "ok", %{summary: "Setup done"})
            :ok

          {:error, output} ->
            output = Secrets.redact(project.secrets, output)
            Pipeline.finish_run(run, "failed", %{summary: output})
            {:error, "Setup failed. #{output}"}
        end
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

        post_then(
          issue,
          project,
          issue.number,
          "**The Developer is blocked:** #{reason}\n\nReply `/factory approve` to try again once it is resolved.",
          fn -> hold(issue, project, "developer_blocked", reason, "developing") end
        )
      else
        with :ok <-
               unless_stopped(issue, fn ->
                 Workspace.impl().commit(path, "Work on ##{issue.number}", [])
               end) do
          gates(issue, project, path, context, attempt, work)
        end
      end
    end
  end

  defp gates(issue, project, path, context, attempt, work) do
    case Pipeline.authorize_run(issue, %{stage: "gates", role: "gates", round: attempt}) do
      {:error, :stopped} -> {:stopped, issue}
      {:ok, run} -> check(run, issue, project, path, context, attempt, work)
    end
  end

  defp check(run, issue, project, path, context, attempt, work) do
    case Gates.impl().check(project, issue, path) do
      :ok ->
        Pipeline.finish_run(run, "ok", %{summary: "Tests and lint pass"})
        deliver(issue, project, path, work)

      {:error, output} ->
        output = Secrets.redact(project.secrets, output)
        Pipeline.finish_run(run, "failed", %{summary: output})

        if attempt < @max_attempts do
          develop(issue, project, path, %{context | gate_failure: output}, attempt + 1)
        else
          post_then(
            issue,
            project,
            issue.number,
            "**The checks still fail after #{attempt} attempts.** Reply `/factory approve` to try again.\n\n```\n#{Factory.Shell.tail(output, 3000)}\n```",
            fn -> hold(issue, project, "gates_failed", output, "developing") end
          )
        end
    end
  end

  # What is compared with the base, checked for secrets and pushed is one commit:
  # the one the issue's branch points to now.
  defp deliver(issue, project, path, work) do
    with {:ok, sha} <- Workspace.impl().head(path, issue) do
      deliver(issue, project, path, work, sha)
    end
  end

  defp deliver(issue, project, path, work, sha) do
    ws = Workspace.impl()

    cond do
      not ws.code_changed?(path, project, sha) ->
        hold(
          issue,
          project,
          "no_changes",
          "The Developer finished without changing any code.",
          "developing"
        )

      issue.pr_number ->
        with :ok <- push(issue, project, path, sha) do
          post_then(
            issue,
            project,
            issue.pr_number,
            "**Changes pushed for review round #{issue.pr_round + 1}.**\n\n#{work["summary"]}",
            fn -> Pipeline.transition(issue, "pr_review", %{}, "Review changes pushed") end
          )
        end

      true ->
        body =
          GitHub.sign(
            Secrets.redact(project.secrets, """
            #{work["summary"]}

            Spec, plan and tasks are in `#{Workspace.plan_dir(issue)}/`.

            Closes ##{issue.number}
            """)
          )

        with :ok <- push(issue, project, path, sha),
             {:ok, pr} <-
               unless_stopped(issue, fn ->
                 GitHub.impl().create_pr(project.repo, %{
                   head: issue.branch,
                   base: project.base_branch,
                   title: issue.title,
                   body: body
                 })
               end) do
          Pipeline.transition(
            issue,
            "pr_review",
            %{pr_number: pr.number, pr_url: pr.url},
            "Pull request ##{pr.number} opened"
          )
        end
    end
  end

  # Pushes `sha`, unless the commits the push would send contain a secret value:
  # then nothing is pushed and the issue waits for a person. If what would be sent
  # cannot be read, nothing is pushed either and the stage fails.
  defp push(issue, project, path, sha) do
    ws = Workspace.impl()

    with {:ok, []} <- leaked_secrets(issue, project, path, sha) do
      unless_stopped(issue, fn -> ws.push(path, issue, sha) end)
    else
      {:ok, names} ->
        list = Enum.map_join(names, ", ", &"`#{&1}`")

        post_then(
          issue,
          project,
          issue.number,
          """
          **Nothing was pushed: the commits contain the value of the project secret(s) #{list}.**

          Reply `/factory approve` to continue; the Developer is asked to remove the values from the commits that are not pushed yet.
          """,
          fn ->
            hold(
              issue,
              project,
              "secret_in_diff",
              "The commits to push contain the value of the secret(s) #{Enum.join(names, ", ")}",
              issue.state
            )
          end
        )

      {:error, _} = error ->
        error
    end
  end

  # The secrets whose values are in the commits a push of `sha` would send.
  defp leaked_secrets(issue, project, path, sha) do
    if Secrets.any?(project.secrets) do
      with {:ok, blocks} <- Workspace.impl().unpushed_changes(path, project, issue, sha) do
        {:ok, Secrets.leaked(project.secrets, blocks)}
      end
    else
      {:ok, []}
    end
  end

  # An approval that still lists blocking problems is not one.
  defp approved?(review), do: review["verdict"] == "approve" and review["blocking"] in [nil, []]

  defp escalate("easy"), do: "medium"
  defp escalate(_), do: "hard"

  ## Shared

  # Runs an effect outside the factory, unless the issue was stopped just before.
  defp unless_stopped(issue, fun) do
    if Pipeline.stopped?(issue), do: {:stopped, issue}, else: fun.()
  end

  # Posts a comment and goes on with `next` whatever GitHub answered, as long as
  # the issue was not stopped.
  defp post_then(issue, project, number, body, next) do
    body = Secrets.redact(project.secrets, body)

    case unless_stopped(issue, fn -> GitHub.post(project.repo, number, body) end) do
      {:stopped, _} = stopped -> stopped
      _posted_or_not -> next.()
    end
  end

  # Parks the issue with a detail that shows no secret value.
  defp hold(issue, project, reason, detail, resume) do
    Pipeline.hold(issue, reason, Secrets.redact(project.secrets, detail), resume)
  end

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
