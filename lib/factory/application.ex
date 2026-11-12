defmodule Factory.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FactoryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
