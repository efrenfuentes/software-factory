defmodule Factory.Projects.Project do
  @moduledoc """
  A GitHub repository the factory works on, with its stack and the model used by each role.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @app_types ~w(rails elixir rust go node)
  @models ~w(claude-fable-5-2 claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5)
  # Codex models, offered only for the Reviewer.
  @codex_models ~w(gpt-6-astra gpt-6.1-sol gpt-6.1-terra gpt-6-luna)
  @efforts ~w(low medium high xhigh max)
  @plan_approvals ~w(never hard always)

  @model_fields ~w(planner_model reviewer_model dev_hard_model dev_medium_model dev_easy_model)a
  @effort_fields ~w(planner_effort reviewer_effort dev_hard_effort dev_medium_effort dev_easy_effort)a

  schema "projects" do
    field :repo, :string
    field :app_type, :string
    field :base_branch, :string, default: "main"
    field :trigger_label, :string, default: "factory:ready"
    field :allowed_users, :string, default: ""
    field :enabled, :boolean, default: true
    field :close_issue_on_merge, :boolean, default: true

    field :planner_model, :string, default: "claude-opus-5-5"
    field :planner_effort, :string, default: "high"
    field :reviewer_model, :string, default: "claude-fable-5-2"
    field :reviewer_effort, :string, default: "medium"
    field :dev_hard_model, :string, default: "claude-opus-5-5"
    field :dev_hard_effort, :string, default: "high"
    field :dev_medium_model, :string, default: "claude-opus-5-5"
    field :dev_medium_effort, :string, default: "medium"
    field :dev_easy_model, :string, default: "claude-sonnet-5-5"
    field :dev_easy_effort, :string, default: "medium"

    field :max_plan_rounds, :integer, default: 3
    field :max_pr_rounds, :integer, default: 3
    field :plan_approval, :string, default: "hard"
    field :max_budget_usd, :decimal

    field :setup_cmd, :string
    field :test_cmd, :string
    field :lint_cmd, :string

    has_many :issues, Factory.Pipeline.Issue

    timestamps(type: :utc_datetime)
  end

  def app_types, do: @app_types
  def models, do: @models
  def codex_models, do: @codex_models
  def efforts, do: @efforts
  def plan_approvals, do: @plan_approvals

  def changeset(project, attrs) do
    project
    |> cast(
      attrs,
      [
        :repo,
        :app_type,
        :base_branch,
        :trigger_label,
        :allowed_users,
        :enabled,
        :close_issue_on_merge,
        :max_plan_rounds,
        :max_pr_rounds,
        :plan_approval,
        :max_budget_usd,
        :setup_cmd,
        :test_cmd,
        :lint_cmd
      ] ++ @model_fields ++ @effort_fields
    )
    |> update_change(:repo, &String.trim/1)
    |> validate_required(
      [:repo, :app_type, :base_branch, :trigger_label, :allowed_users, :plan_approval] ++
        @model_fields ++ @effort_fields
    )
    |> validate_format(:repo, ~r{^[\w.-]+/[\w.-]+$}, message: "must look like owner/name")
    |> validate_inclusion(:app_type, @app_types)
    |> validate_inclusion(:plan_approval, @plan_approvals)
    |> validate_number(:max_plan_rounds, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_number(:max_pr_rounds, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> validate_number(:max_budget_usd, greater_than: 0)
    |> validate_each(@model_fields -- [:reviewer_model], @models)
    |> validate_inclusion(:reviewer_model, @models ++ @codex_models)
    |> validate_each(@effort_fields, @efforts)
    |> unique_constraint(:repo)
  end

  defp validate_each(changeset, fields, allowed) do
    Enum.reduce(fields, changeset, &validate_inclusion(&2, &1, allowed))
  end

  @doc "GitHub logins whose comments the factory acts on."
  def allowed_logins(%__MODULE__{allowed_users: users}) do
    users
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.map(&(&1 |> String.trim_leading("@") |> String.downcase()))
  end

  @doc "Model and effort for a role. The developer's depends on the issue difficulty."
  def model_for(%__MODULE__{} = p, :planner), do: {p.planner_model, p.planner_effort}
  def model_for(%__MODULE__{} = p, :reviewer), do: {p.reviewer_model, p.reviewer_effort}

  def model_for(%__MODULE__{} = p, {:developer, "easy"}),
    do: {p.dev_easy_model, p.dev_easy_effort}

  def model_for(%__MODULE__{} = p, {:developer, "hard"}),
    do: {p.dev_hard_model, p.dev_hard_effort}

  def model_for(%__MODULE__{} = p, {:developer, _}), do: {p.dev_medium_model, p.dev_medium_effort}
end
