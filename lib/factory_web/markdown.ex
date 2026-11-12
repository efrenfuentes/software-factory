defmodule FactoryWeb.Markdown do
  @moduledoc """
  Renders text written by agents as HTML.

  The text comes from a model that read GitHub content, so it is never trusted:
  raw HTML in it is shown as text and the result is sanitized.
  """

  @options [
    extension: [autolink: true, strikethrough: true, table: true],
    sanitize: MDEx.Document.default_sanitize_options(),
    syntax_highlight: nil
  ]

  @doc """
  With `breaks: true` (the default) a single line break is kept, which suits
  short answers. Files wrapped at a fixed width want `breaks: false`.
  """
  @spec to_html(String.t() | nil, keyword()) :: Phoenix.HTML.safe()
  def to_html(text, opts \\ [])
  def to_html(nil, _opts), do: {:safe, ""}

  def to_html(text, opts) do
    render = [escape: true, hardbreaks: Keyword.get(opts, :breaks, true)]

    case MDEx.to_html(text, [{:render, render} | @options]) do
      {:ok, html} -> {:safe, html}
      {:error, _} -> Phoenix.HTML.html_escape(text)
    end
  end
end
