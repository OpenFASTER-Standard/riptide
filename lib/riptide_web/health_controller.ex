defmodule RiptideWeb.HealthController do
  use Phoenix.Controller

  def show(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
