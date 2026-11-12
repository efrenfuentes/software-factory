defmodule FactoryWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use FactoryWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active, :atom, default: nil, doc: "the section to highlight: :issues or :projects"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-20 border-b border-base-300 bg-base-100/85 backdrop-blur">
      <div class="mx-auto flex h-14 max-w-6xl items-center gap-2 px-3 sm:gap-6 sm:px-6">
        <.link
          navigate={~p"/"}
          class="flex shrink-0 items-center gap-2.5 rounded font-semibold tracking-tight"
          aria-label="Software Factory"
        >
          <span class="flex items-center" aria-hidden="true">
            <span class="size-2 rounded-full bg-base-content" />
            <span class="h-px w-2 bg-base-content" />
            <span class="size-2 rounded-full bg-primary" />
            <span class="h-px w-2 bg-base-content/40" />
            <span class="size-2 rounded-full border border-base-content/40" />
          </span>
          <span class="hidden sm:inline">Software Factory</span>
        </.link>
        <nav class="flex h-full flex-1 items-stretch gap-1 text-sm" aria-label="Main">
          <.nav_link navigate={~p"/"} active={@active == :issues}>Issues</.nav_link>
          <.nav_link navigate={~p"/projects"} active={@active == :projects}>Projects</.nav_link>
        </nav>
        <.theme_toggle />
      </div>
    </header>

    <main class="mx-auto max-w-6xl px-3 py-6 sm:px-6 sm:py-8">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "relative flex items-center px-2.5 transition sm:px-3",
        if(@active,
          do:
            "font-medium text-base-content after:absolute after:inset-x-2 after:bottom-0 after:h-0.5 after:bg-primary",
          else: "text-base-content/60 hover:text-base-content"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      class="flex shrink-0 items-center rounded-md border border-base-300 p-0.5"
      role="group"
      aria-label="Theme"
    >
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", "Match the system"},
            {"light", "hero-sun-micro", "Light"},
            {"dark", "hero-moon-micro", "Dark"}
          ]
        }
        type="button"
        class={[
          "grid size-8 cursor-pointer place-items-center rounded text-base-content/50 transition hover:text-base-content sm:size-7",
          theme == "system" &&
            "[html:not([data-theme])_&]:bg-base-200 [html:not([data-theme])_&]:text-base-content",
          theme == "light" &&
            "[[data-theme=light]_&]:bg-base-200 [[data-theme=light]_&]:text-base-content",
          theme == "dark" &&
            "[[data-theme=dark]_&]:bg-base-200 [[data-theme=dark]_&]:text-base-content"
        ]}
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={label}
        title={label}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    """
  end
end
