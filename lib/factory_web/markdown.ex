defmodule FactoryWeb.Markdown do
  @moduledoc """
  Renders text written by agents as HTML.

  The text comes from a model that read GitHub content, so it is never trusted:
  raw HTML in it is shown as text and the result is sanitized.
  """

  @options [
    extension: [autolink: true, strikethrough: true, table: true],
    render: [escape: true, hardbreaks: true],
    sanitize: MDEx.Document.default_sanitize_options(),
    syntax_highlight: nil
  ]

  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: {:safe, ""}

  def to_html(text) do
    case MDEx.to_html(text, @options) do
      {:ok, html} -> {:safe, html}
      {:error, _} -> Phoenix.HTML.html_escape(text)
    end
  end
end
