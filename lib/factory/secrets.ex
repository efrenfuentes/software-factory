defmodule Factory.Secrets do
  @moduledoc """
  A project's secrets: environment variables with values that only the checks
  and the Developer get, stored encrypted and never shown again.

  The panel lists, adds, replaces and deletes them without ever reading a value
  back. A stage loads them once (`load/1`), passes them to the processes that
  may see them (`env/2`) and replaces their values in every text the factory
  stores or publishes (`redact/2`), and refuses to push commits that contain one
  (`leaked/2`).
  """
  import Ecto.Query
  alias Factory.Accounts.User
  alias Factory.Projects.Project
  alias Factory.Repo
  alias Factory.Secrets.{Bundle, Cipher, ProjectSecret}
  alias Factory.Shell.Env

  ## Panel

  @listed [:id, :project_id, :name, :checks_only, :key_fingerprint, :updated_by_id] ++
            [:inserted_at, :updated_at]

  @doc "The project's secrets, by name, with who changed them last — without their values."
  def list_secrets(%Project{id: project_id}) do
    Repo.all(
      from s in ProjectSecret,
        where: s.project_id == ^project_id,
        order_by: s.name,
        select: struct(s, ^@listed),
        preload: :updated_by
    )
  end

  @doc "One of the project's secrets, without its value."
  def get_secret!(%Project{id: project_id}, id) do
    Repo.one!(
      from s in ProjectSecret,
        where: s.project_id == ^project_id and s.id == ^id,
        select: struct(s, ^@listed)
    )
  end

  @doc "Like `get_secret!/2`, but nil when there is no such secret (or `id` is not one)."
  def get_secret(%Project{id: project_id}, id) do
    case parse_id(id) do
      nil ->
        nil

      id ->
        Repo.one(
          from s in ProjectSecret,
            where: s.project_id == ^project_id and s.id == ^id,
            select: struct(s, ^@listed)
        )
    end
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  def change_secret(secret \\ %ProjectSecret{}, attrs \\ %{}),
    do: ProjectSecret.create_changeset(secret, attrs)

  def change_replace(%ProjectSecret{} = secret, attrs \\ %{}),
    do: ProjectSecret.replace_changeset(secret, attrs)

  @doc "Adds a secret. Without a key, `{:error, :no_key}`."
  def create_secret(%Project{} = project, attrs, %User{} = user) do
    with {:ok, key} <- key() do
      changeset =
        %ProjectSecret{project_id: project.id, updated_by_id: user.id}
        |> ProjectSecret.create_changeset(attrs)

      changeset
      |> encrypt(key, project.id, Ecto.Changeset.get_field(changeset, :name))
      |> Repo.insert()
      |> clear_value()
    end
  end

  @doc """
  Writes a new value and/or `checks_only` for a secret; an empty value keeps the
  old one. Without a key, `{:error, :no_key}`.
  """
  def replace_secret(%ProjectSecret{} = secret, attrs, %User{} = user) do
    with {:ok, key} <- key() do
      secret
      |> ProjectSecret.replace_changeset(attrs)
      |> Ecto.Changeset.put_change(:updated_by_id, user.id)
      |> Ecto.Changeset.force_change(:updated_at, DateTime.truncate(DateTime.utc_now(), :second))
      |> encrypt(key, secret.project_id, secret.name)
      |> Repo.update()
      |> clear_value()
    end
  end

  def delete_secret(%ProjectSecret{} = secret), do: Repo.delete(secret)

  # The encrypted value replaces the plain one, which is dropped from the changeset.
  defp encrypt(%Ecto.Changeset{valid?: true} = changeset, key, project_id, name) do
    case Ecto.Changeset.get_change(changeset, :value) do
      nil ->
        changeset

      value ->
        {:ok, blob} = Cipher.encrypt(value, Cipher.aad(project_id, name), key)

        changeset
        |> Ecto.Changeset.delete_change(:value)
        |> Ecto.Changeset.put_change(:encrypted_value, blob)
        |> Ecto.Changeset.put_change(:key_fingerprint, Cipher.fingerprint(key))
    end
  end

  defp encrypt(changeset, _key, _project_id, _name), do: changeset

  defp clear_value({:ok, secret}), do: {:ok, %{secret | value: nil, encrypted_value: nil}}

  defp clear_value({:error, changeset}),
    do: {:error, %{changeset | changes: Map.drop(changeset.changes, [:value, :encrypted_value])}}

  defp key do
    case Cipher.key() do
      {:ok, key} -> {:ok, key}
      _ -> {:error, :no_key}
    end
  end

  @doc "Whether `FACTORY_SECRETS_KEY` is set, so secrets can be added and replaced."
  def key_available?, do: match?({:ok, _}, Cipher.key())

  @doc "The fingerprint of the current key, or nil without one."
  def current_fingerprint do
    case Cipher.key() do
      {:ok, key} -> Cipher.fingerprint(key)
      _ -> nil
    end
  end

  @doc "Whether a secret's name is reserved, so the secret is not used."
  def reserved?(name), do: Env.reserved?(name)

  ## Stages

  @doc """
  Decrypts the project's secrets for a stage. A project without secrets loads
  an empty bundle whether there is a key or not; one whose secrets cannot be
  decrypted gets an error that names them, without any value.
  """
  @spec load(Project.t()) :: {:ok, Bundle.t()} | {:error, String.t()}
  def load(%Project{id: project_id}) do
    rows =
      Repo.all(from s in ProjectSecret, where: s.project_id == ^project_id, order_by: s.name)

    case {rows, Cipher.key()} do
      {[], _} ->
        {:ok, Bundle.empty()}

      {rows, {:ok, key}} ->
        {entries, failed} =
          Enum.reduce(rows, {[], []}, fn row, {entries, failed} ->
            case Cipher.decrypt(row.encrypted_value, Cipher.aad(row.project_id, row.name), key) do
              {:ok, value} ->
                {[%{name: row.name, value: value, checks_only: row.checks_only} | entries],
                 failed}

              :error ->
                {entries, [row.name | failed]}
            end
          end)

        if failed == [],
          do: {:ok, Bundle.new(entries)},
          else:
            {:error,
             "The project secrets #{names(failed)} cannot be decrypted with the current " <>
               "FACTORY_SECRETS_KEY (stored with another key, or altered). Write them again " <>
               "in the project's Secrets section, then retry."}

      {rows, _no_key} ->
        {:error,
         "FACTORY_SECRETS_KEY is not set, so the project secrets #{names(rows)} cannot be " <>
           "decrypted. Set the key in the service's environment, then retry."}
    end
  end

  defp names(rows_or_names) do
    rows_or_names
    |> Enum.map(fn
      %ProjectSecret{name: name} -> name
      name -> name
    end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  @doc """
  The variables a process gets: all the usable secrets for the checks, those
  not "only for the checks" for the Developer, none for anyone else. A secret
  whose name is reserved is never passed.
  """
  def env(nil, _who), do: []

  def env(%Bundle{entries: entries}, who) when who in [:checks, :developer] do
    for entry <- entries,
        not Env.reserved?(entry.name),
        who == :checks or not entry.checks_only,
        do: {entry.name, entry.value}
  end

  def env(%Bundle{}, _who), do: []

  @doc """
  Replaces every secret value in `term` (a text, or maps, lists and tuples of them) by
  `[SECRET:NAME]`; at each position the longest fragment wins.
  """
  def redact(nil, term), do: term
  def redact(%Bundle{fragments: []}, term), do: term

  def redact(%Bundle{fragments: fragments}, term) do
    names = Map.new(fragments)
    redact_term(term, Enum.map(fragments, &elem(&1, 0)), names)
  end

  defp redact_term(text, patterns, names) when is_binary(text),
    do: String.replace(text, patterns, &"[SECRET:#{Map.fetch!(names, &1)}]")

  defp redact_term(list, patterns, names) when is_list(list),
    do: Enum.map(list, &redact_term(&1, patterns, names))

  defp redact_term(tuple, patterns, names) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> redact_term(patterns, names) |> List.to_tuple()
  end

  defp redact_term(%_{} = struct, _patterns, _names), do: struct

  defp redact_term(%{} = map, patterns, names) do
    Map.new(map, fn {key, value} ->
      {redact_term(key, patterns, names), redact_term(value, patterns, names)}
    end)
  end

  defp redact_term(other, _patterns, _names), do: other

  @doc """
  The names of the secrets whose fragments appear in `text`, or in any one of
  a list of blocks (each block is searched on its own, never joined to another).
  """
  def leaked(nil, _text), do: []

  def leaked(%Bundle{fragments: fragments}, blocks) do
    blocks = List.wrap(blocks)

    fragments
    |> Enum.filter(fn {fragment, _} -> Enum.any?(blocks, &String.contains?(&1, fragment)) end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The names the Developer is told about: those it gets, and those only the checks get."
  def prompt_names(nil), do: %{available: [], checks_only: []}

  def prompt_names(%Bundle{entries: entries}) do
    usable = Enum.reject(entries, &Env.reserved?(&1.name))

    %{
      available: for(e <- usable, not e.checks_only, do: e.name),
      checks_only: for(e <- usable, e.checks_only, do: e.name)
    }
  end

  @doc "Whether there is any secret value to look for."
  def any?(%Bundle{entries: [_ | _]}), do: true
  def any?(_), do: false
end
