defmodule Riptide.SupervisedProcess.SessionTrackerTest do
  use ExUnit.Case, async: true

  alias Riptide.SupervisedProcess.SessionTracker

  test "an id with no recorded session reports not active at crash" do
    id = "session-#{System.unique_integer([:positive])}"
    refute SessionTracker.was_active_at_crash?(id)
  end

  test "mark_session_active/1 then was_active_at_crash?/1 reports true" do
    id = "session-#{System.unique_integer([:positive])}"
    :ok = SessionTracker.mark_session_active(id)
    assert SessionTracker.was_active_at_crash?(id)
  end

  test "mark_session_idle/1 after mark_session_active/1 reports false" do
    id = "session-#{System.unique_integer([:positive])}"
    :ok = SessionTracker.mark_session_active(id)
    :ok = SessionTracker.mark_session_idle(id)
    refute SessionTracker.was_active_at_crash?(id)
  end
end
