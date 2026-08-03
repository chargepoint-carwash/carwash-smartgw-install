#!/usr/bin/env bash

# Apply .env changes to a running carwash-smartgw container.
#
# Editing .env and running "docker restart" does NOT work: the container is
# created with --env-file, so Docker bakes those values in as real environment
# variables, and @nestjs/config skips any key already present in process.env.
# The container has to be recreated. This script does that safely:
#
#   - pins the image already running, so the app version does not change
#   - reuses the current port and the labels Watchtower needs
#   - derives the serial --device from SERIAL_PORT in the .env
#   - backs up the .env, and rolls back automatically if the app fails to start

set -euo pipefail

function display_usage() {
  cat <<EOF
Usage: apply_env.sh [options]

Edits the .env, recreates the container so the change takes effect, and
verifies the app comes back healthy.

Options:
  --set KEY=VALUE  Set a key without opening an editor. May be repeated.
  --no-edit        Do not open an editor (use after editing .env by hand).
  --container      Application container name (default: carwash-smartgw)
  --app-dir        Directory holding .env
                   (default: /opt/<container> on Linux, ~/.docker/<container> on macOS)
  --editor         Editor to use (default: \$EDITOR, else nano)
  --no-rollback    Keep the new .env even if the app fails its health check.
  --help           Display this help message

Examples:
  sudo ./apply_env.sh                                 # edit interactively, then apply
  sudo ./apply_env.sh --set SERIAL_PORT=/dev/ttyS0    # one-shot change
  sudo ./apply_env.sh --no-edit                       # apply an edit you already made
EOF
}

function log_info() {
  local -r GREEN="\033[0;32m"
  local -r NO_COLOR="\033[0m"
  echo -e "${GREEN}[INFO] $1${NO_COLOR}"
}

function log_warn() {
  local -r YELLOW="\033[0;33m"
  local -r NO_COLOR="\033[0m"
  echo -e "${YELLOW}[WARN] $1${NO_COLOR}"
}

function log_error() {
  local -r RED="\033[0;31m"
  local -r NO_COLOR="\033[0m"
  echo -e "${RED}[ERROR] $1${NO_COLOR}" >&2
}

function command_exists() {
  command -v "$@" &> /dev/null
}

# Same helper install_server.sh uses, so both write the file identically.
function upsert_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -qE "^${key}=" "${file}"; then
    local escaped_value
    escaped_value=$(printf '%s\n' "${value}" | sed 's/[\\&@]/\\&/g')
    sed -i.bak -E "s@^${key}=.*@${key}=${escaped_value}@" "${file}"
    rm -f "${file}.bak"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

CONTAINER_NAME="carwash-smartgw"
APP_DIR=""
CONTAINER_APP_DIR="/usr/src/app"
EDITOR_CMD="${EDITOR:-nano}"
NO_EDIT=false
NO_ROLLBACK=false
SET_PAIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --set)
      SET_PAIRS+=("$2")
      shift 2
      ;;
    --no-edit)
      NO_EDIT=true
      shift
      ;;
    --container)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --app-dir)
      APP_DIR="$2"
      shift 2
      ;;
    --editor)
      EDITOR_CMD="$2"
      shift 2
      ;;
    --no-rollback)
      NO_ROLLBACK=true
      shift
      ;;
    --help)
      display_usage
      exit 0
      ;;
    --)
      shift
      ;;
    *)
      log_error "Unknown option: $1"
      display_usage
      exit 1
      ;;
  esac
done

# Mirrors the default resolution in install_server.sh.
if [[ -z "${APP_DIR}" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
      APP_DIR="/Users/${SUDO_USER}/.docker/${CONTAINER_NAME}"
    else
      APP_DIR="${HOME}/.docker/${CONTAINER_NAME}"
    fi
  else
    APP_DIR="/opt/${CONTAINER_NAME}"
  fi
fi

ENV_FILE="${APP_DIR}/.env"

if ! command_exists docker; then
  log_error "Docker is not installed."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  log_error "Cannot access Docker. Re-run with sudo on Linux, or start Docker Desktop on macOS."
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  log_error "No .env found at ${ENV_FILE}."
  log_error "Use --app-dir if it lives elsewhere, or run install_server.sh first."
  exit 1
fi

if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  log_error "Container ${CONTAINER_NAME} does not exist; there is nothing to update."
  log_error "Run install_server.sh to create it first."
  exit 1
fi

# Read the running container's settings BEFORE removing it. Pinning to the
# image ID means applying a config change never also moves the app version.
IMAGE="$(docker inspect -f '{{.Image}}' "${CONTAINER_NAME}")"
PORT="$(docker inspect -f '{{with index .HostConfig.PortBindings "3000/tcp"}}{{(index . 0).HostPort}}{{end}}' "${CONTAINER_NAME}")"
# Some Docker versions omit StopTimeout entirely; the "index" form yields an
# empty string instead of aborting the template.
STOP_TIMEOUT="$(docker inspect -f '{{with index .HostConfig "StopTimeout"}}{{.}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
if [[ -z "${STOP_TIMEOUT}" || "${STOP_TIMEOUT}" == "<no value>" ]]; then
  STOP_TIMEOUT=60
fi
MOUNTS_DEV=false
if docker inspect -f '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' "${CONTAINER_NAME}" | grep -q '/dev:/dev'; then
  MOUNTS_DEV=true
fi

if [[ -z "${PORT}" ]]; then
  log_error "Could not determine the host port of ${CONTAINER_NAME}."
  exit 1
fi

BACKUP="${ENV_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
cp "${ENV_FILE}" "${BACKUP}"

for pair in ${SET_PAIRS[@]+"${SET_PAIRS[@]}"}; do
  if [[ "${pair}" != *=* ]]; then
    log_error "--set expects KEY=VALUE, got: ${pair}"
    exit 1
  fi
  upsert_env_value "${pair%%=*}" "${pair#*=}" "${ENV_FILE}"
  log_info "Set ${pair%%=*}."
done

# Only open an editor when there is nothing else to go on.
if [[ "${NO_EDIT}" != true && ${#SET_PAIRS[@]} -eq 0 ]]; then
  if ! command_exists "${EDITOR_CMD}"; then
    log_error "Editor '${EDITOR_CMD}' not found. Use --editor, or --set/--no-edit."
    exit 1
  fi
  "${EDITOR_CMD}" "${ENV_FILE}"
fi

if diff -q "${BACKUP}" "${ENV_FILE}" >/dev/null; then
  log_info "No changes to ${ENV_FILE}; leaving the container alone."
  rm -f "${BACKUP}"
  exit 0
fi

echo ""
log_info "Changes to apply:"
diff "${BACKUP}" "${ENV_FILE}" || true
echo ""

# SERIAL_PORT drives the device passthrough, so read it back from the file the
# user just edited rather than from the old container.
SERIAL_PORT="$(grep -E '^SERIAL_PORT=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ' || true)"

function start_container() {
  local device_args=()
  if [[ "${MOUNTS_DEV}" == true ]]; then
    device_args=(-v /dev:/dev)
  elif [[ -n "${SERIAL_PORT}" && -e "${SERIAL_PORT}" ]]; then
    device_args=(--device "${SERIAL_PORT}:${SERIAL_PORT}")
  elif [[ -n "${SERIAL_PORT}" ]]; then
    log_warn "Serial device ${SERIAL_PORT} not found on this host; starting without passthrough."
  fi

  # These flags match install_server.sh. The Watchtower labels matter: without
  # them Watchtower silently stops updating this container forever.
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart always \
    -p "${PORT}:3000" \
    ${device_args[@]+"${device_args[@]}"} \
    --env-file "${ENV_FILE}" \
    -v "${ENV_FILE}:${CONTAINER_APP_DIR}/.env:ro" \
    --stop-timeout "${STOP_TIMEOUT}" \
    --label 'com.centurylinklabs.watchtower.enable=true' \
    --label "com.centurylinklabs.watchtower.scope=${CONTAINER_NAME}" \
    --log-driver local \
    --privileged \
    "${IMAGE}" >/dev/null
}

function wait_for_health() {
  local deadline=$((SECONDS + 60))

  if ! command_exists curl; then
    log_warn "curl not found; falling back to a container status check."
    sleep 5
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
    return $?
  fi

  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    if curl -fsS --max-time 5 "http://localhost:${PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done

  return 1
}

log_info "Recreating ${CONTAINER_NAME} (image pinned, version unchanged)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null
start_container

log_info "Waiting for http://localhost:${PORT}/health ..."
if wait_for_health; then
  log_info "Application is healthy. Configuration applied."
  log_info "Previous .env saved at ${BACKUP}"
  curl -fsS "http://localhost:${PORT}/health" 2>/dev/null || true
  echo ""
  exit 0
fi

log_error "Application did not become healthy after the change."
docker logs --tail 30 "${CONTAINER_NAME}" 2>&1 || true

if [[ "${NO_ROLLBACK}" == true ]]; then
  # Not "${0}": when run as bash -c "$(curl ...)" -- ... that expands to "--".
  log_warn "--no-rollback set; keeping the new .env. Restore it with:"
  log_warn "  cp ${BACKUP} ${ENV_FILE} && apply_env.sh --no-edit --container ${CONTAINER_NAME}"
  exit 1
fi

log_warn "Rolling back to the previous .env..."
cp "${BACKUP}" "${ENV_FILE}"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
SERIAL_PORT="$(grep -E '^SERIAL_PORT=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ' || true)"
start_container

if wait_for_health; then
  log_info "Rolled back successfully; the device is running the previous configuration."
else
  log_error "Rollback also failed to become healthy. Check: docker logs ${CONTAINER_NAME}"
fi

exit 1
