.DEFAULT_GOAL := help

CONTAINERFILE ?= Containerfile
IMAGE ?= oracle-pr-sentry:local
NAME ?= oracle-pr-sentry
HOST_IP ?= 127.0.0.1
PORT ?= 6080
CPUS ?= 4
MEMORY ?= 4G
VNC_GEOMETRY ?= 1440x900
VNC_DEPTH ?= 24
VNC_PASSWORD ?=
HOME_VOLUME ?= oracle-pr-sentry-home
WORKSPACE_DIR ?=
MIN_MACOS_MAJOR ?= 26

export CONTAINERFILE IMAGE NAME HOST_IP PORT CPUS MEMORY VNC_GEOMETRY VNC_DEPTH
export VNC_PASSWORD HOME_VOLUME WORKSPACE_DIR MIN_MACOS_MAJOR

.PHONY: help check build pull up down status shell gh-login oracle-login run dry-run clean

help check build pull up down status shell gh-login oracle-login run dry-run clean:
	@./container.sh $@
