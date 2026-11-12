defmodule Factory.Accounts do
  @moduledoc "The people who can sign in to the factory, and their sessions."
  import Ecto.Query
  alias Factory.Accounts.{User, UserToken}
  alias Factory.Repo

  ## Users

  def list_users, do: Repo.all(from u in User, order_by: [u.first_name, u.last_name, u.id])
  def get_user!(id), do: Repo.get!(User, id)
  def any_users?, do: Repo.exists?(User)

  def change_user(%User{} = user, attrs \\ %{}), do: User.admin_changeset(user, attrs)

  def create_user(attrs), do: %User{} |> User.admin_changeset(attrs) |> Repo.insert()

  @doc """
  Creates the first account, as an administrator. Only works while there are no
  users, which is how a new installation gets its first one.
  """
  def create_first_admin(attrs) do
    Repo.transaction(fn ->
      # Two people opening the setup page at once must not both succeed.
      Repo.query!("LOCK TABLE users IN EXCLUSIVE MODE")

      if any_users?() do
        Repo.rollback(:already_set_up)
      else
        attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("role", "admin")

        case create_user(attrs) do
          {:ok, user} -> user
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end
    end)
  end

  @doc """
  Updates an account. The factory must always keep one active administrator, and
  any change to role, status or password signs the person out everywhere so it
  takes effect at once. Returns the session tokens that were ended.
  """
  def update_user(%User{} = user, attrs) do
    changeset = User.admin_changeset(user, attrs)

    Repo.transaction(fn ->
      # One change at a time: two administrators demoting each other at the same
      # moment must not both succeed.
      Repo.query!("LOCK TABLE users IN SHARE ROW EXCLUSIVE MODE")

      with {:ok, updated} <- Repo.update(changeset),
           :ok <- keep_an_admin(changeset) do
        ended =
          if Enum.any?([:role, :active, :hashed_password], &Map.has_key?(changeset.changes, &1)),
            do: delete_sessions(updated),
            else: []

        {updated, ended}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Whether this is the only active administrator, whose role and status cannot change."
  def last_admin?(%User{role: "admin", active: true, id: id}) when not is_nil(id) do
    not Repo.exists?(from u in User, where: u.role == "admin" and u.active and u.id != ^id)
  end

  def last_admin?(%User{}), do: false

  defp keep_an_admin(changeset) do
    if Repo.exists?(from u in User, where: u.role == "admin" and u.active) do
      :ok
    else
      {:error,
       changeset
       |> Ecto.Changeset.add_error(
         :role,
         "this is the only active administrator; make someone else one first"
       )
       |> Map.put(:action, :update)}
    end
  end

  ## Passwords

  def change_password(%User{} = user, attrs \\ %{}), do: User.password_changeset(user, attrs)

  @doc "A person changes their own password. Their other sessions are ended."
  def update_password(%User{} = user, current_password, attrs) do
    changeset = User.password_changeset(user, attrs)

    if User.valid_password?(user, current_password || "") do
      Repo.transaction(fn ->
        case Repo.update(changeset) do
          {:ok, user} -> {user, delete_sessions(user)}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    else
      {:error, Ecto.Changeset.add_error(changeset, :current_password, "is not correct")}
    end
  end

  ## Sessions

  @doc "The active user with this email and password, if any."
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email |> String.trim() |> String.downcase())
    if User.valid_password?(user, password) and user.active, do: user
  end

  def create_session(%User{} = user) do
    {token, record} = UserToken.build(user)
    Repo.insert!(record)
    token
  end

  def get_user_by_session(token) when is_binary(token), do: Repo.one(UserToken.user_query(token))
  def get_user_by_session(_token), do: nil

  def delete_session(token) when is_binary(token) do
    Repo.delete_all(from t in UserToken, where: t.token == ^token)
    :ok
  end

  def delete_session(_token), do: :ok

  defp delete_sessions(%User{id: id}) do
    {_count, tokens} =
      Repo.delete_all(from t in UserToken, where: t.user_id == ^id, select: t.token)

    tokens
  end
end
