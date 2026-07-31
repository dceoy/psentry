.DEFAULT_GOAL := help

CONTAINERFILE ?= Containerfile
IMAGE ?= psentry:local
NAME ?= psentry
HOST_IP ?= 127.0.0.1
PORT ?= 6080
CPUS ?= 4
MEMORY ?= 4G
POLL_INTERVAL ?= 15m
VNC_GEOMETRY ?= 1440x900
VNC_DEPTH ?= 24
VNC_PASSWORD ?=
HOME_VOLUME ?= psentry-home

export CONTAINERFILE IMAGE NAME HOST_IP PORT CPUS MEMORY POLL_INTERVAL
export VNC_GEOMETRY VNC_DEPTH VNC_PASSWORD HOME_VOLUME

.PHONY: help build up down status gh-login oracle-login run dry-run clean

help build up down status gh-login oracle-login run dry-run clean:
	@./container.sh $@
