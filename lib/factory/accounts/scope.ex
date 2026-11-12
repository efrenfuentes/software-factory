defmodule Factory.Accounts.Scope do
  @moduledoc """
  Who is making a request and what they may do. It is assigned as
  `current_scope` to every connection and LiveView.
  """
  alias Factory.Accounts.User

  defstruct user: nil

  @type t :: %__MODULE__{user: User.t() | nil}

  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  @doc """
  Whether the scope allows an ability:

    * `:manage` - create and change projects and users (administrators)
    * `:operate` - act on issues (administrators and operators)
    * `:view` - read (anyone signed in)
  """
  def can?(%__MODULE__{user: %User{role: "admin"}}, _ability), do: true
  def can?(%__MODULE__{user: %User{role: "operator"}}, ability), do: ability in [:operate, :view]
  def can?(%__MODULE__{user: %User{}}, ability), do: ability == :view
  def can?(_scope, _ability), do: false

  @doc "The person's name, for notes on what they did."
  def name(%__MODULE__{user: %User{} = user}), do: User.full_name(user)
end
