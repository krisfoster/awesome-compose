#!/usr/bin/env bash
#
# Bring up the nginx-golang sample inside a Docker Sandbox (sbx) microVM.
#
# Layers when this finishes:
#   host -> sbx microVM -> devcontainer -> `code tunnel` (URL printed at the end)
#
# From that VS Code tunnel URL, `docker compose up` in a terminal starts the
# sample; VS Code's port panel forwards the proxy port back to your browser.
#
# Two paths:
#   1. If the `sbx kit` experimental commands work on your build, the kit at
#      .sbx/spec.yaml does everything (recommended).
#   2. Otherwise this script does the same steps by hand.
#
# Prerequisites: Docker Desktop with Docker Sandboxes enabled, and the `sbx`
# CLI on PATH.

set -euo pipefail

SANDBOX_NAME="${SANDBOX_NAME:-nginx-golang}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v sbx >/dev/null 2>&1; then
	echo "error: sbx CLI not found. Install Docker Sandboxes and try again." >&2
	echo "       https://docs.docker.com/ai/sandboxes/get-started/" >&2
	exit 1
fi

if sbx ls 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$SANDBOX_NAME"; then
	echo "sandbox '$SANDBOX_NAME' already exists; re-attach with:"
	echo "  sbx run --name $SANDBOX_NAME"
	exit 0
fi

echo "==> Creating sandbox '$SANDBOX_NAME' with the nginx-golang kit"
sbx create \
	--name "$SANDBOX_NAME" \
	--kit "$REPO_ROOT/.sbx" \
	shell "$REPO_ROOT"

echo
echo "==> Waiting for the sandbox's Docker daemon to be ready"
for _ in $(seq 1 30); do
	if sbx exec "$SANDBOX_NAME" -- docker info >/dev/null 2>&1; then
		break
	fi
	sleep 1
done

echo "==> Bringing up the devcontainer (first run pulls the base image)"
sbx exec "$SANDBOX_NAME" -- \
	devcontainer up \
		--workspace-folder "$REPO_ROOT" \
		--remove-existing-container

echo
echo "==> Locating the devcontainer inside the sandbox"
DEVCONTAINER_ID="$(
	sbx exec "$SANDBOX_NAME" -- \
		docker ps --filter label=devcontainer.local_folder -q | head -n 1
)"

if [ -z "${DEVCONTAINER_ID:-}" ]; then
	echo "error: no devcontainer found in sandbox '$SANDBOX_NAME'." >&2
	echo "       Check logs with: sbx exec $SANDBOX_NAME -- journalctl --user -e" >&2
	exit 1
fi

echo "==> Waiting for the tunnel URL"
for _ in $(seq 1 30); do
	TUNNEL_URL="$(
		sbx exec "$SANDBOX_NAME" -- \
			docker exec "$DEVCONTAINER_ID" \
			sh -c 'cat /tmp/tunnel.log 2>/dev/null | grep -oE "https://vscode\.dev/tunnel/[A-Za-z0-9._/-]+" | head -n 1' \
		|| true
	)"
	if [ -n "${TUNNEL_URL:-}" ]; then
		break
	fi
	sleep 2
done

echo
if [ -n "${TUNNEL_URL:-}" ]; then
	echo "VS Code tunnel:"
	echo "  $TUNNEL_URL"
else
	echo "Tunnel is still starting. First run needs interactive device-code auth."
	echo "Tail the tunnel log to find the code + URL:"
	echo "  sbx exec $SANDBOX_NAME -- docker exec $DEVCONTAINER_ID cat /tmp/tunnel.log"
fi
echo
echo "To tear the sandbox down: sbx rm --force $SANDBOX_NAME"
