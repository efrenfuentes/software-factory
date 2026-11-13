defmodule Factory.Repo.Migrations.CreateProjectSecrets do
  use Ecto.Migration

  def change do
    create table(:project_secrets) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :encrypted_value, :binary, null: false
      add :checks_only, :boolean, null: false, default: false
      add :key_fingerprint, :string, null: false
      add :updated_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_secrets, [:project_id, :name])
  end
end
