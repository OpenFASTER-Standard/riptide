# syntax=docker/dockerfile:1

# ---- Builder ----
FROM hexpm/elixir:1.18.4-erlang-25.3.2.21-debian-bookworm-20260803 AS builder

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY rel rel

RUN mix compile
RUN mix release

# ---- Runtime ----
FROM debian:bookworm-slim AS runtime

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

RUN groupadd --gid 1000 riptide && \
    useradd --uid 1000 --gid riptide --shell /bin/bash --create-home riptide

RUN mkdir -p /data && chown riptide:riptide /data

WORKDIR /app
RUN chown riptide:riptide /app

COPY --from=builder --chown=riptide:riptide /app/_build/prod/rel/riptide ./

USER riptide

ENV RIPTIDE_RA_DATA_DIR=/data
ENV PHX_SERVER=true
ENV PORT=4000

# Default for the single-node/docker-compose path, where no POD_IP is set:
# distribution stays fully disabled (node() fixed at `nonode@nohost`, no
# distribution port). This used to be load-bearing for on-disk data too,
# back when `:ra` namespaced its data directory by `node()` (`ra_env:data_dir/0`)
# and an unstable node name across container recreation would silently point
# at an empty directory. Phase 3b (Clustering/HA) removed that premise:
# `Riptide.RaCluster.data_dir/0` now keys `:ra`'s data directory off the
# `HOSTNAME` env var instead of `node()`, so distribution identity and
# on-disk data location are decoupled.
#
# That's what makes it safe for `rel/env.sh.eex` to re-enable real
# distributed Erlang (RELEASE_DISTRIBUTION=name, RELEASE_NODE=riptide@$POD_IP)
# on top of this default, but only when POD_IP is present — i.e. only under
# the Kubernetes StatefulSet deployment path, where each pod's stable
# HOSTNAME (its pod name) keeps the data directory stable across recreation
# regardless of what node name distribution uses. See that file and
# `RaCluster.data_dir/0`'s moduledoc comment for the full picture.
ENV RELEASE_DISTRIBUTION=none

VOLUME ["/data"]
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:4000/health || exit 1

CMD ["bin/riptide", "start"]
