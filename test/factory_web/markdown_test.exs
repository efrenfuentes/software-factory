defmodule FactoryWeb.MarkdownTest do
  use ExUnit.Case, async: true
  alias FactoryWeb.Markdown

  defp html(text), do: text |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  test "renders the Markdown agents write" do
    html = html("Change `a + b` to **a - b**.\n\n- one\n- two\nsee https://example.com")

    assert html =~ "<code>a + b</code>"
    assert html =~ "<strong>a - b</strong>"
    assert html =~ "<li>one</li>"
    assert html =~ ~s(href="https://example.com")
  end

  test "keeps single line breaks" do
    assert html("line one\nline two") =~ "line one<br>"

    refute Markdown.to_html("line one\nline two", breaks: false) |> Phoenix.HTML.safe_to_string() =~
             "<br>"
  end

  test "shows raw HTML as text and never produces scripts, handlers or script links" do
    html =
      html("""
      <script>alert(1)</script> <img src=x onerror=alert(1)>

      Inline <b onclick="x()">bold</b> and [link](javascript:alert(1)).
      """)

    document = LazyHTML.from_fragment(html)

    for selector <- ["script", "img", "b", "[onclick]", "[onerror]", "a[href^='javascript']"] do
      assert Enum.empty?(LazyHTML.query(document, selector)), "found #{selector} in #{html}"
    end

    assert html =~ "&lt;script&gt;"
  end

  test "nothing renders as nothing" do
    assert html(nil) == ""
  end
end
