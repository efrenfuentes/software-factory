defmodule Factory.GitHub do
  @moduledoc """
  What the factory needs from GitHub. Comments the factory writes carry a hidden
  marker, because it posts with the same account a person uses to answer.
  """

  @marker "<!-- software-factory -->"

  @type issue :: %{number: integer(), title: String.t(), body: String.t(), url: String.t()}
  @type comment :: %{author: String.t(), body: String.t(), created_at: DateTime.t()}

  @callback list_issues(repo :: String.t(), label :: String.t()) ::
              {:ok, [issue]} | {:error, term()}
  @callback get_issue(repo :: String.t(), number :: integer()) ::
              {:ok,
               %{title: String.t(), body: String.t(), state: String.t(), comments: [comment]}}
              | {:error, term()}
  @callback comment(repo :: String.t(), number :: integer(), body :: String.t()) ::
              :ok | {:error, term()}
  @callback create_pr(repo :: String.t(), attrs :: map()) ::
              {:ok, %{number: integer(), url: String.t()}} | {:error, term()}
  @callback get_pr(repo :: String.t(), number :: integer()) ::
              {:ok, %{state: String.t()}} | {:error, term()}
  @callback set_label(
              repo :: String.t(),
              number :: integer(),
              label :: String.t(),
              present? :: boolean()
            ) :: :ok
  @callback close_issue(repo :: String.t(), number :: integer(), comment :: String.t()) ::
              :ok | {:error, term()}
  @callback current_user() :: {:ok, String.t()} | {:error, term()}

  def impl, do: Application.fetch_env!(:factory, :github)

  def marker, do: @marker
  def sign(body), do: body <> "\n\n" <> @marker
  def from_factory?(%{body: body}), do: String.contains?(body, @marker)

  @doc "Posts a comment signed as coming from the factory."
  def post(repo, number, body), do: impl().comment(repo, number, sign(body))
end
