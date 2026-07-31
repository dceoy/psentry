# syntax=docker/dockerfile:1

FROM docker.io/library/node:24-bookworm-slim AS oracle

# renovate: datasource=npm depName=@steipete/oracle
ARG ORACLE_VERSION='0.16.1'

# hadolint ignore=DL3016
RUN \
      npm install --global "@steipete/oracle@${ORACLE_VERSION}" \
      && npm cache clean --force \
      && node --version \
      && oracle --version

FROM docker.io/library/debian:13-slim

ARG DEBIAN_FRONTEND='noninteractive'
ARG USER_NAME='agent'
ARG USER_UID='1001'
ARG USER_GID='1001'
ARG VNC_GEOMETRY='1440x900'
ARG VNC_DEPTH='24'
ARG NOVNC_PORT='6080'

LABEL \
  org.opencontainers.image.title="oracle-pr-sentry" \
  org.opencontainers.image.description="Oracle pull request sentry for Apple Container" \
  org.opencontainers.image.source="https://github.com/dceoy/oracle-pr-sentry" \
  org.opencontainers.image.licenses="MIT"

ENV \
  CHROME_PATH='/usr/bin/chromium' \
  DISPLAY=':1' \
  NOVNC_PORT="${NOVNC_PORT}" \
  ORACLE_ENGINE='browser' \
  ORACLE_PR_SENTRY_PROMPT_PATH='/usr/local/share/oracle-pr-sentry/review-prompt.md' \
  VNC_DEPTH="${VNC_DEPTH}" \
  VNC_GEOMETRY="${VNC_GEOMETRY}"

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# hadolint ignore=DL3008,DL3009
RUN \
      --mount=type=cache,target=/var/cache/apt,sharing=locked \
      --mount=type=cache,target=/var/lib/apt,sharing=locked \
      rm -f /etc/apt/apt.conf.d/docker-clean \
      && printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n' \
        > /etc/apt/apt.conf.d/99oracle-pr-sentry-keep-cache \
      && printf 'Acquire::Retries "10";\nAcquire::http::Timeout "60";\nAcquire::https::Timeout "60";\n' \
        > /etc/apt/apt.conf.d/99oracle-pr-sentry-network-retries \
      && apt-get -yqq update \
      && apt-get -yqq upgrade \
      && apt-get -yqq install --no-install-recommends --no-install-suggests \
        bash ca-certificates chromium coreutils curl dbus dbus-x11 findutils \
        fonts-noto-cjk gawk gh git grep jq novnc procps \
        tigervnc-standalone-server tigervnc-tools tini util-linux vim \
        websockify xfce4 xfce4-terminal \
      && apt-get -yqq autoremove --purge

COPY --from=oracle /usr/local/ /usr/local/

RUN \
      node --version \
      && oracle --version \
      && groupadd --gid "${USER_GID}" "${USER_NAME}" \
      && useradd \
        --uid "${USER_UID}" \
        --gid "${USER_GID}" \
        --shell /bin/bash \
        --create-home \
        "${USER_NAME}" \
      && mkdir -p \
        /opt/home-skel/.config/oracle-pr-sentry \
        /opt/home-skel/.local/share/oracle-pr-sentry/oracle-home \
        /usr/local/share/oracle-pr-sentry \
        /workspace \
      && cp -a "/home/${USER_NAME}/." /opt/home-skel/ \
      && chmod 700 \
        /opt/home-skel/.config/oracle-pr-sentry \
        /opt/home-skel/.local/share/oracle-pr-sentry/oracle-home

COPY --chmod=0755 bin/oracle-pr-sentry /usr/local/bin/oracle-pr-sentry
COPY --chmod=0755 container/entrypoint.sh /usr/local/bin/oracle-pr-sentry-entrypoint
COPY --chmod=0600 config/env.example /opt/home-skel/.config/oracle-pr-sentry/env
COPY --chmod=0644 share/oracle-pr-sentry/review-prompt.md \
  /usr/local/share/oracle-pr-sentry/review-prompt.md
COPY --chmod=0644 share/oracle-pr-sentry/decision-reducer.jq \
  /usr/local/share/oracle-pr-sentry/decision-reducer.jq

RUN chown -R "${USER_NAME}:${USER_NAME}" /opt/home-skel /workspace

ENV \
  HOME="/home/${USER_NAME}" \
  USER_NAME="${USER_NAME}" \
  WORKSPACE_DIR='/workspace'

USER ${USER_NAME}
WORKDIR /workspace

EXPOSE ${NOVNC_PORT}

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["bash", "-c", "< /dev/tcp/127.0.0.1/${NOVNC_PORT}"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/oracle-pr-sentry-entrypoint"]
