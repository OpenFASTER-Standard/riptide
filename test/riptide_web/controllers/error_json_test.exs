defmodule RiptideWeb.ErrorJSONTest do
  use RiptideWeb.ConnCase, async: true

  test "renders 404" do
    assert RiptideWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert RiptideWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
