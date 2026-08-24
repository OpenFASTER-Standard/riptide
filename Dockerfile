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

# `:ra` namespaces its on-disk data under a per-node subdirectory keyed by
# `node()` (see `ra_env:data_dir/0`), so the Erlang node name must be stable
# across container recreation for the volume-durability guarantee to hold —
# otherwise a freshly recreated container (new hostname, since `mix
# release`'s default `sname` distribution derives the node name from the
# container's hostname) would compute a *different* subdirectory under the
# same `/data` mount and find it empty. This app is single-node only for
# now (see `Riptide.RaCluster`'s module doc), so distributed Erlang buys it
# nothing yet; disabling it entirely makes `node()` the fixed
# `nonode@nohost` on every boot, which sidesteps the whole hostname problem
# (and drops the distribution port besides). Revisit if/when the
# Clustering/HA sub-project needs real multi-node distributed Erlang.
ENV RELEASE_DISTRIBUTION=none

VOLUME ["/data"]
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:4000/health || exit 1

CMD ["bin/riptide", "start"]
