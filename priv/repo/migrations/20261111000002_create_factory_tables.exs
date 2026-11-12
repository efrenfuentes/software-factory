defmodule Factory.Repo.Migrations.CreateFactoryTables do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :repo, :string, null: false
      add :app_type, :string, null: false
      add :base_branch, :string, null: false, default: "main"
      add :trigger_label, :string, null: false, default: "factory:ready"
      add :allowed_users, :string, null: false, default: ""
      add :enabled, :boolean, null: false, default: true

      add :planner_model, :string, null: false
      add :planner_effort, :string, null: false
      add :reviewer_model, :string, null: false
      add :reviewer_effort, :string, null: false
      add :dev_hard_model, :string, null: false
      add :dev_hard_effort, :string, null: false
      add :dev_medium_model, :string, null: false
      add :dev_medium_effort, :string, null: false
      add :dev_easy_model, :string, null: false
      add :dev_easy_effort, :string, null: false

      add :max_plan_rounds, :integer, null: false, default: 3
      add :max_pr_rounds, :integer, null: false, default: 3
      add :plan_approval, :string, null: false, default: "hard"
      add :max_budget_usd, :decimal

      add :setup_cmd, :string
      add :test_cmd, :string
      add :lint_cmd, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:repo])

    create table(:issues) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :title, :string, null: false
      add :url, :string
      add :body_hash, :string
      add :state, :string, null: false, default: "queued"
      add :state_entered_at, :utc_datetime_usec, null: false
      add :difficulty, :string
      add :plan_round, :integer, null: false, default: 0
      add :plan_round_limit, :integer, null: false
      add :pr_round, :integer, null: false, default: 0
      add :pr_round_limit, :integer, null: false
      add :branch, :string
      add :pr_number, :integer
      add :pr_url, :string
      add :hold_reason, :string
      add :hold_detail, :text
      add :resume_state, :string
      add :comments_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create unique_index(:issues, [:project_id, :number])
    create index(:issues, [:state])

    # One row per state the issue has been in; `left_at` is nil for the current one.
    create table(:transitions) do
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :state, :string, null: false
      add :note, :text
      add :entered_at, :utc_datetime_usec, null: false
      add :left_at, :utc_datetime_usec
    end

    create index(:transitions, [:issue_id])

    # One row per agent or gate execution.
    create table(:stage_runs) do
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :stage, :string, null: false
      add :role, :string, null: false
      add :round, :integer, null: false, default: 0
      add :model, :string
      add :effort, :string
      add :status, :string, null: false, default: "running"
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :input_tokens, :bigint
      add :output_tokens, :bigint
      add :cost_usd, :decimal
      add :summary, :text
      add :output, :map
    end

    create index(:stage_runs, [:issue_id])
  end
end
