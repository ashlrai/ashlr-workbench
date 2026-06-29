#!/usr/bin/env bash
# config.sh — centralized defaults for ashlr-workbench.
#
# Source this file from any workbench script to get consistent defaults with
# environment-variable overrides.  Every variable uses the ${VAR:-default}
# pattern so callers can override any value without editing this file.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
#
# Override any value by setting the env var before sourcing, or in .env:
#   LM_STUDIO_URL=http://localhost:5000/v1 aw start ashlrcode

# Guard against double-sourcing.
if [ -n "${_ASHLR_CONFIG_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_CONFIG_SOURCED=1

# ─── Workbench root ───────────────────────────────────────────────────────────
# Scripts that source this file can rely on WORKBENCH being set to the repo
# root, regardless of where they live on disk.  The one caller that previously
# hardcoded an absolute path (start-aider.sh, start-ashlrcode.sh) is fixed by
# this canonical derivation.
_CONFIG_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${WORKBENCH:="$(cd "$_CONFIG_SH_DIR/../.." && pwd)"}"
export WORKBENCH

# ─── LM Studio ────────────────────────────────────────────────────────────────
# Host-side URL (used by healthcheck, status, start-aider, aw-session, etc.)
: "${LM_STUDIO_URL:=http://localhost:1234/v1}"
export LM_STUDIO_URL

# Default model id for LM Studio (OpenAI-compatible endpoint id).
: "${LM_STUDIO_MODEL:=qwen/qwen3-coder-30b}"
export LM_STUDIO_MODEL

# LM Studio CLI path (used by mode-switch.sh).
: "${LMS_CLI:=$HOME/.lmstudio/bin/lms}"
export LMS_CLI

# ─── Ollama ───────────────────────────────────────────────────────────────────
: "${OLLAMA_URL:=http://localhost:11434}"
export OLLAMA_URL

: "${OLLAMA_MODEL_FAST:=llama3.2:3b}"
export OLLAMA_MODEL_FAST

: "${OLLAMA_MODEL_REASONING:=gemma4:26b}"
export OLLAMA_MODEL_REASONING

# ─── OpenHands container ─────────────────────────────────────────────────────
: "${OPENHANDS_CONTAINER:=ashlr-openhands}"
export OPENHANDS_CONTAINER

: "${OPENHANDS_PORT:=3000}"
export OPENHANDS_PORT

: "${OPENHANDS_IMAGE:=ghcr.io/openhands/openhands:1.6.0}"
export OPENHANDS_IMAGE

: "${OPENHANDS_AGENT_SERVER_IMAGE:=ghcr.io/openhands/agent-server:1.15.0-python}"
export OPENHANDS_AGENT_SERVER_IMAGE

# Pre-built sandbox runtime image.  Update when bumping OPENHANDS_IMAGE.
: "${OPENHANDS_SANDBOX_IMAGE:=ghcr.io/openhands/runtime:oh_v1.6.0_93pv7lc0x29cbiqa_3j4mdepm5f3d15vq}"
export OPENHANDS_SANDBOX_IMAGE

# LLM URL as seen from inside the Docker container (host.docker.internal on
# macOS; use LM_STUDIO_URL for host-side probes).
: "${OPENHANDS_LLM_BASE_URL:=http://host.docker.internal:1234/v1}"
export OPENHANDS_LLM_BASE_URL

: "${OPENHANDS_LLM_MODEL:=openai/$LM_STUDIO_MODEL}"
export OPENHANDS_LLM_MODEL

: "${OPENHANDS_LLM_API_KEY:=local-llm}"
export OPENHANDS_LLM_API_KEY

: "${OPENHANDS_CONTEXT_LENGTH:=32768}"
export OPENHANDS_CONTEXT_LENGTH

# ─── Paths ────────────────────────────────────────────────────────────────────
: "${ASHLR_PLUGIN_DIR:=$HOME/Desktop/ashlr-plugin}"
export ASHLR_PLUGIN_DIR

: "${OPENHANDS_STATE_DIR:=$HOME/.openhands}"
export OPENHANDS_STATE_DIR

: "${OPENHANDS_WORKSPACE_HOST:=$HOME/Desktop}"
export OPENHANDS_WORKSPACE_HOST

: "${OPENHANDS_CACHE_DIR:=$HOME/.cache/ashlr-workbench}"
export OPENHANDS_CACHE_DIR

# Architecture-specific bun download URL.  Override for x86_64 or custom builds.
: "${BUN_LINUX_ARCH:=aarch64}"
export BUN_LINUX_ARCH

: "${BUN_VERSION_URL:=https://github.com/oven-sh/bun/releases/latest/download/bun-linux-${BUN_LINUX_ARCH}.zip}"
export BUN_VERSION_URL
