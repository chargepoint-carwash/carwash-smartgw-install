#!/usr/bin/env bash

# Uninstaller for carwash-smartgw. Reverses install_server.sh: removes the app
# and Watchtower containers, and the config directory.
#
# Images and registry credentials are kept unless explicitly requested, since
# they are usually shared with other things on the host.

set -euo pipefail

function display_usage() {
  cat <<EOF
Usage: uninstall_server.sh [options]

Options:
  --container   Name of the application container (default: carwash-smartgw)
  --app-dir     Directory holding .env and the Watchtower auth config
                (default: /opt/<container> on Linux, ~/.docker/<container> on macOS)
  --keep-config Keep the config directory. It contains in
                plaintext, so only use this when reinstalling shortly after.
  --remove-images
                Also remove the application and Watchtower images.
  --image       Application image to remove with --remove-images. Defaults to
                whatever the running container was created from.
  --logout      Also run 'docker logout' for the image's registry. Affects every
                image from that registry on this host, not just this app.
  --yes         Do not ask for confirmation.
  --help        Display this help message
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

function confirm() {
  echo -n "> $1 [y/N] "
  local RESPONSE
  read -r RESPONSE
  RESPONSE=$(echo "${RESPONSE}" | tr '[:upper:]' '[:lower:]') || return
  [[ "${RESPONSE}" == "y" || "${RESPONSE}" == "yes" ]]
}

function command_exists() {
  command -v "$@" &> /dev/null
}

function container_exists() {
  docker ps -a --format '{{.Names}}' | grep -q "^$1$"
}

function remove_container() {
  local name="$1"

  if ! container_exists "${name}"; then
    log_info "Container ${name} is not present; nothing to remove."
    return 0
  fi

  # --restart always means a plain 'docker stop' would come back after a reboot,
  # so the container has to be removed, not just stopped.
  log_info "Removing container ${name}..."
  docker rm -f "${name}" >/dev/null
  log_info "Removed container ${name}."
}

OS_NAME="$(uname -s)"
IS_MACOS=false
case "${OS_NAME}" in
  Darwin) IS_MACOS=true ;;
  Linux) ;;
  *)
    log_error "Unsupported operating system: ${OS_NAME}. This script supports Ubuntu/Linux and macOS."
    exit 1
    ;;
esac

CONTAINER_NAME="carwash-smartgw"
APP_DIR=""
KEEP_CONFIG=false
REMOVE_IMAGES=false
IMAGE=""
DO_LOGOUT=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --app-dir)
      APP_DIR="$2"
      shift 2
      ;;
    --keep-config)
      KEEP_CONFIG=true
      shift
      ;;
    --remove-images)
      REMOVE_IMAGES=true
      shift
      ;;
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --logout)
      DO_LOGOUT=true
      shift
      ;;
    --yes)
      ASSUME_YES=true
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

WATCHTOWER_CONTAINER="watchtower-${CONTAINER_NAME}"

# Mirrors the default resolution in install_server.sh.
if [[ -z "${APP_DIR}" ]]; then
  if [[ "${IS_MACOS}" == true ]]; then
    if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
      APP_DIR="/Users/${SUDO_USER}/.docker/${CONTAINER_NAME}"
    else
      APP_DIR="${HOME}/.docker/${CONTAINER_NAME}"
    fi
  else
    APP_DIR="/opt/${CONTAINER_NAME}"
  fi
fi

if ! command_exists docker; then
  log_error "Docker is not installed, so there is nothing to uninstall."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  log_error "Cannot access Docker. Start Docker, or re-run with sudo on Linux."
  exit 1
fi

# Resolve the image from the container before it is removed, so --remove-images
# works without the caller having to remember which tag was installed.
if [[ "${REMOVE_IMAGES}" == true && -z "${IMAGE}" ]] && container_exists "${CONTAINER_NAME}"; then
  IMAGE="$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
fi

echo ""
log_info "About to remove:"
echo "  - container ${CONTAINER_NAME}"
echo "  - container ${WATCHTOWER_CONTAINER}"
if [[ "${KEEP_CONFIG}" == true ]]; then
  echo "  - (keeping ${APP_DIR})"
else
  echo "  - directory ${APP_DIR}"
fi
if [[ "${REMOVE_IMAGES}" == true ]]; then
  echo "  - images ${IMAGE:-<app image>} and containrrr/watchtower"
fi
if [[ "${DO_LOGOUT}" == true ]]; then
  echo "  - registry credentials (docker logout)"
fi
echo ""

if [[ "${ASSUME_YES}" != true ]] && ! confirm "Proceed?"; then
  log_info "Aborted; nothing was changed."
  exit 0
fi

# Watchtower first: it watches containers by label and should not be running
# while the app container is being torn down.
remove_container "${WATCHTOWER_CONTAINER}"
remove_container "${CONTAINER_NAME}"

if [[ "${KEEP_CONFIG}" == true ]]; then
  log_warn "Keeping ${APP_DIR}."
elif [[ -d "${APP_DIR}" ]]; then
  log_info "Removing configuration directory ${APP_DIR}..."
  if rm -rf "${APP_DIR}"; then
    log_info "Removed ${APP_DIR}."
  else
    log_error "Could not remove ${APP_DIR}. Re-run with sudo."
    exit 1
  fi
else
  log_info "Configuration directory ${APP_DIR} does not exist; nothing to remove."
fi

if [[ "${REMOVE_IMAGES}" == true ]]; then
  for image in "${IMAGE}" "containrrr/watchtower"; do
    if [[ -z "${image}" ]]; then
      continue
    fi
    if docker image inspect "${image}" >/dev/null 2>&1; then
      log_info "Removing image ${image}..."
      docker rmi "${image}" >/dev/null 2>&1 ||
        log_warn "Could not remove ${image}; it is probably still used by another container."
    fi
  done
fi

if [[ "${DO_LOGOUT}" == true ]]; then
  REGISTRY_HOST=""
  IMAGE_FIRST_PART="${IMAGE%%/*}"
  if [[ "${IMAGE}" == */* ]] &&
    [[ "${IMAGE_FIRST_PART}" == *.* || "${IMAGE_FIRST_PART}" == *:* || "${IMAGE_FIRST_PART}" == "localhost" ]]; then
    REGISTRY_HOST="${IMAGE_FIRST_PART}"
  fi

  log_info "Logging out of ${REGISTRY_HOST:-Docker Hub}..."
  docker logout ${REGISTRY_HOST:+"${REGISTRY_HOST}"} >/dev/null 2>&1 || true
fi

echo ""
log_info "Uninstall complete."

REMAINING="$(docker ps -a --format '{{.Names}}' | grep -E "^(${CONTAINER_NAME}|${WATCHTOWER_CONTAINER})$" || true)"
if [[ -n "${REMAINING}" ]]; then
  log_error "These containers still exist: ${REMAINING}"
  exit 1
fi

cat <<EOF

Docker itself was left installed. To remove it as well:
  Ubuntu:  sudo apt-get purge docker-ce docker-ce-cli containerd.io && sudo rm -rf /var/lib/docker
  macOS:   uninstall Docker Desktop from Applications
EOF
