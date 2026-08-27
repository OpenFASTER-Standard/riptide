-- Same as wrk-put.lua, but each request PUTs a DIFFERENT resource path
-- (round-robin over a fixed pool) instead of hammering one — see the
-- top-level README's "Performance" section for why this matters: writes to
-- the SAME resource serialize through that resource's own single-writer Ra
-- log, so this is the benchmark that actually exercises Riptide's
-- per-resource write parallelism.
wrk.method = "PUT"
wrk.body = io.open("test/bench/put_body.ttl", "r"):read("*a")
wrk.headers["Content-Type"] = "text/turtle"

local pool_size = 500
local counter = 0

request = function()
  counter = counter + 1
  local path = "/tenants/http-bench-tenant/resources/put-pool-" .. (counter % pool_size)
  return wrk.format(nil, path)
end
