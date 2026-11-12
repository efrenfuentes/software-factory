defmodule Factory.Repo do
  use Ecto.Repo,
    otp_app: :factory,
    adapter: Ecto.Adapters.Postgres
end
