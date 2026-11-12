defmodule Factory.Accounts.UserToken do
  @moduledoc "A signed-in browser session. Deleting the row signs that browser out."
  use Ecto.Schema
  import Ecto.Query

  @session_days 14

  schema "users_tokens" do
    field :token, :binary
    belongs_to :user, Factory.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def build(user) do
    token = :crypto.strong_rand_bytes(32)
    {token, %__MODULE__{token: token, user_id: user.id}}
  end

  @doc "The active user behind a session token that has not expired."
  def user_query(token) do
    from t in __MODULE__,
      join: u in assoc(t, :user),
      where: t.token == ^token and t.inserted_at > ago(@session_days, "day") and u.active,
      select: u
  end
end
