defmodule Factory.Secrets.ProjectSecret do
  @moduledoc """
  An environment variable with a secret value for a project's checks and
  Developer. The value is only stored encrypted (`Factory.Secrets.Cipher`);
  `value` is virtual and only carries what a person typed into the changeset.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Factory.Shell.Env

  @type t :: %__MODULE__{}

  @max_bytes 32_768

  schema "project_secrets" do
    field :name, :string
    field :encrypted_value, :binary, redact: true
    field :value, :string, virtual: true, redact: true
    field :checks_only, :boolean, default: false
    field :key_fingerprint, :string

    belongs_to :project, Factory.Projects.Project
    belongs_to :updated_by, Factory.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  A new secret: name, value and whether only the checks get it. `checks_only`
  may be left out (false), but not given as nil or as anything but a boolean.
  """
  def create_changeset(secret, attrs) do
    secret
    |> cast(attrs, [:name, :value, :checks_only])
    |> update_change(:name, &String.trim/1)
    |> normalize_value()
    |> validate_required([:name, :value, :checks_only])
    |> validate_name()
    |> validate_value()
    |> unique_constraint([:project_id, :name],
      error_key: :name,
      message: "already exists — use Replace"
    )
  end

  @doc "A new value and/or `checks_only` for an existing secret. An empty value keeps the old one."
  def replace_changeset(secret, attrs) do
    secret
    |> cast(attrs, [:value, :checks_only])
    |> validate_required([:checks_only])
    |> normalize_value()
    |> validate_value()
  end

  # `\r\n` becomes `\n`; a one-line value loses the blanks around it, a multiline one is kept.
  defp normalize_value(changeset) do
    case get_change(changeset, :value) do
      nil ->
        changeset

      value ->
        value = String.replace(value, "\r\n", "\n")
        trimmed = String.trim(value)

        cond do
          trimmed == "" -> delete_change(changeset, :value)
          String.contains?(trimmed, "\n") -> put_change(changeset, :value, value)
          true -> put_change(changeset, :value, trimmed)
        end
    end
  end

  defp validate_name(changeset) do
    changeset
    |> validate_length(:name, max: 128)
    |> validate_format(:name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/,
      message: "must start with a letter or _ and have only letters, digits and _"
    )
    |> validate_change(:name, fn :name, name ->
      if Env.reserved?(name),
        do: [name: "is reserved: the factory sets it or passes it to every command"],
        else: []
    end)
  end

  defp validate_value(changeset) do
    changeset
    |> validate_length(:value, min: 8)
    |> validate_length(:value, max: @max_bytes, count: :bytes)
    |> validate_change(:value, fn :value, value ->
      if String.contains?(value, <<0>>), do: [value: "must not contain a NUL byte"], else: []
    end)
  end
end
