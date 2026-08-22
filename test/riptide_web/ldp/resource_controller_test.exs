defmodule RiptideWeb.LDP.ResourceControllerTest do
  use ExUnit.Case, async: true
  use Plug.Test

  @opts RiptideWeb.Endpoint.init([])

  defp unique_path, do: "/resources/test-#{System.unique_integer([:positive])}"

  test "GET on a resource that was never written to returns 404" do
    conn = :get |> conn(unique_path()) |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 404
  end

  test "PUT creates a resource, and GET then returns its Turtle state" do
    path = unique_path()
    turtle = "<https://pod.example/x> <https://pod.example/y> \"z\" .\n"

    put_conn =
      :put
      |> conn(path, turtle)
      |> put_req_header("content-type", "text/turtle")
      |> RiptideWeb.Endpoint.call(@opts)

    assert put_conn.status == 201

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 200
    assert get_conn.resp_body =~ "\"z\""
  end

  test "PATCH applies an additive delta on top of existing state" do
    path = unique_path()

    :put
    |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"1\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    patch_body =
      Jason.encode!(%{
        "additions" => "<https://pod.example/x> <https://pod.example/y> \"2\" .\n",
        "removals" => ""
      })

    patch_conn =
      :patch
      |> conn(path, patch_body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert patch_conn.status == 200

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn.resp_body =~ "\"1\""
    assert get_conn.resp_body =~ "\"2\""
  end

  test "DELETE removes the resource's visible state" do
    path = unique_path()

    :put
    |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"z\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    delete_conn = :delete |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert delete_conn.status == 204

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn.status == 404
  end
end
