defmodule Factory.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    check_secrets_config()

    children = [
      FactoryWeb.Telemetry,
      Factory.Repo,
      {DNSCluster, query: Application.get_env(:factory, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Factory.PubSub},
      {Oban, Application.fetch_env!(:factory, Oban)},
      # Start to serve requests, typically the last entry
      FactoryWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Factory.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # A malformed key stops the start; a missing one only disables the project secrets.
  defp check_secrets_config do
    Factory.Secrets.Cipher.check_key!()

    if Factory.Secrets.Cipher.key() == :missing do
      Logger.warning(
        "FACTORY_SECRETS_KEY is not set: projects with secrets cannot run. " <>
          "Generate one with: openssl rand -base64 32"
      )
    end

    for name <- Factory.Shell.Env.invalid_passthrough() do
      Logger.warning("FACTORY_ENV_PASSTHROUGH: ignoring #{inspect(name)}, not a valid name")
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FactoryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
