defmodule Factory.Agents do
  @moduledoc """
  Runs one agent for one stage and records it as a stage run, with the model,
  effort, duration, tokens and cost that the dashboard shows.
  """
  alias Factory.Pipeline
  alias Factory.Pipeline.Issue
  alias Factory.Projects.Project

  @type request :: %{
          role: :planner | :reviewer | :developer,
          prompt: String.t(),
          schema: map(),
          model: String.t(),
          effort: String.t(),
          cwd: String.t(),
          max_budget_usd: Decimal.t() | nil
        }
  @type result :: %{
          output: map(),
          cost_usd: number() | nil,
          input_tokens: integer() | nil,
          output_tokens: integer() | nil
        }

  @callback run(request) :: {:ok, result} | {:error, String.t()}

  def impl, do: Application.fetch_env!(:factory, :agent_runner)

  @doc """
  `tier` only matters for the developer: it is the difficulty whose model to use.
  """
  @spec run(Issue.t(), Project.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def run(
        %Issue{} = issue,
        %Project{} = project,
        %{role: role, stage: stage, round: round} = spec
      ) do
    {model, effort} =
      Project.model_for(
        project,
        if(role == :developer, do: {:developer, spec[:tier] || issue.difficulty}, else: role)
      )

    run =
      Pipeline.start_run(issue, %{
        stage: stage,
        role: to_string(role),
        round: round,
        model: model,
        effort: effort
      })

    request = %{
      role: role,
      prompt: spec.prompt,
      schema: spec.schema,
      model: model,
      effort: effort,
      cwd: spec.cwd,
      max_budget_usd: project.max_budget_usd
    }

    case impl().run(request) do
      {:ok, result} ->
        Pipeline.finish_run(run, "ok", %{
          output: result.output,
          summary: result.output["summary"],
          cost_usd: result[:cost_usd] && Decimal.from_float(result.cost_usd / 1),
          input_tokens: result[:input_tokens],
          output_tokens: result[:output_tokens]
        })

        {:ok, result.output}

      {:error, reason} ->
        Pipeline.finish_run(run, "failed", %{summary: String.slice(reason, 0, 2000)})
        {:error, "#{role} agent failed: #{reason}"}
    end
  end
end
