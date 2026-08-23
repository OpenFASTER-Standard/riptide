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

  test "PATCH removals actually remove a triple on the next GET" do
    path = unique_path()

    :put
    |> conn(path, "<https://s> <https://p> <https://o> .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    patch_body =
      Jason.encode!(%{
        "additions" => "",
        "removals" => "<https://s> <https://p> <https://o> .\n"
      })

    patch_conn =
      :patch
      |> conn(path, patch_body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert patch_conn.status == 200

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn.status == 404
  end

  test "PUT with an empty body is visible (200, empty) and distinct from DELETE (404)" do
    path = unique_path()

    :put
    |> conn(path, "")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn.status == 200
    assert get_conn.resp_body == ""

    delete_conn = :delete |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert delete_conn.status == 204

    get_conn2 = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn2.status == 404
  end

  test "PUT with malformed Turtle returns 400 instead of crashing" do
    path = unique_path()

    put_conn =
      :put
      |> conn(path, "this is not valid turtle <<<")
      |> put_req_header("content-type", "text/turtle")
      |> RiptideWeb.Endpoint.call(@opts)

    assert put_conn.status == 400
  end

  test "PATCH with malformed Turtle in additions returns 400 instead of crashing" do
    path = unique_path()

    :put
    |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"1\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    patch_body =
      Jason.encode!(%{
        "additions" => "this is not valid turtle <<<",
        "removals" => ""
      })

    patch_conn =
      :patch
      |> conn(path, patch_body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert patch_conn.status == 400
  end

  test "PATCH with a missing additions/removals key returns 400 instead of crashing" do
    path = unique_path()

    :put
    |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"1\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    patch_body = Jason.encode!(%{"additions" => ""})

    patch_conn =
      :patch
      |> conn(path, patch_body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert patch_conn.status == 400
  end

  test "POST to a container with malformed Turtle returns 400 instead of crashing" do
    container_path = unique_path()

    post_conn =
      :post
      |> conn(container_path, "this is not valid turtle <<<")
      |> put_req_header("content-type", "text/turtle")
      |> RiptideWeb.Endpoint.call(@opts)

    assert post_conn.status == 400
  end

  test "POST to a container creates a child resource and records ldp:contains" do
    container_path = unique_path()
    child_turtle = "<https://pod.example/a> <https://pod.example/b> \"c\" .\n"

    post_conn =
      :post
      |> conn(container_path, child_turtle)
      |> put_req_header("content-type", "text/turtle")
      |> RiptideWeb.Endpoint.call(@opts)

    assert post_conn.status == 201
    [location] = Plug.Conn.get_resp_header(post_conn, "location")
    assert location =~ container_path

    child_get_conn = :get |> conn(location) |> RiptideWeb.Endpoint.call(@opts)
    assert child_get_conn.status == 200
    assert child_get_conn.resp_body =~ "\"c\""

    container_get_conn = :get |> conn(container_path) |> RiptideWeb.Endpoint.call(@opts)
    assert container_get_conn.resp_body =~ "ldp#contains"
  end
end
