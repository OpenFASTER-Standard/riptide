-- PUT benchmark script for wrk — see the top-level README's "Performance"
-- section. Overwrites the same resource path from every request (a
-- realistic "update an existing resource" write, not a stream-creating one)
-- so repeated runs don't accumulate unbounded stream state.
wrk.method = "PUT"
wrk.body = io.open("test/bench/put_body.ttl", "r"):read("*a")
wrk.headers["Content-Type"] = "text/turtle"
