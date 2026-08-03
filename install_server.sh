#!/usr/bin/env bash

# VPS Installation Script for carwash-smartgw NestJS App
# Inspired by Jigsaw Outline install script
# Ensures Docker is installed, configures private Docker Hub auth, and runs application + Watchtower

set -euo pipefail

function display_usage() {
  cat <<EOF
Usage: install_server.sh [options]

Options:
  --image       The Docker image reference. The registry host is derived from it:
                username/app:tag pulls from Docker Hub, registry.example.com/project/app:tag
                pulls from that registry (e.g. a self-hosted Harbor).
  --port        The host port to bind the application to (default: 3000)
  --container   The name of the application container (default: carwash-smartgw)
  --machine-id
                Machine ID for gateway registration and API authentication
  --machine-secret
                Machine secret for API authentication
  --server-api-base-url
                Shared API host; gateway path/version is composed in code
                (default: https://carwash-api.vn01.zodinet.tech)
  --app-dir     Directory for .env and Watchtower auth config
                (default: /opt/<container> on Linux, ~/.docker/<container> on macOS)
  --serial-port
                Host RS-485 serial device (default: /dev/ttyUSB0). It is passed
                into the container and written to .env as SERIAL_PORT.
                Use "all" or "/dev" to mount the entire /dev directory and expose
                all ports. (--serial-device is accepted as an alias.)
  --username    Registry username (optional, will prompt if private repo)
  --password    Registry password/token (optional, will prompt if private repo)
  --interval    Watchtower polling interval in seconds (default: 3600 / 1 hour)
  --stop-timeout
                Seconds Docker waits after SIGTERM before killing the app (default: 60)
  --pre-rollout-url
                Optional URL to poll before replacing the current app container.
                The rollout continues only after this URL returns HTTP 2xx/3xx.
  --pre-rollout-timeout
                Seconds to wait for --pre-rollout-url (default: 300)
  --help        Display this help message
EOF
}

# Logger utilities
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
  echo -n "> $1 [Y/n] "
  local RESPONSE
  read -r RESPONSE
  RESPONSE=$(echo "${RESPONSE}" | tr '[:upper:]' '[:lower:]') || return
  [[ -z "${RESPONSE}" || "${RESPONSE}" == "y" || "${RESPONSE}" == "yes" ]]
}

function command_exists() {
  command -v "$@" &> /dev/null
}

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

function prompt_machine_credentials() {
  if [[ -z "${MACHINE_ID}" ]]; then
    echo -n "Enter Machine ID: "
    read -r MACHINE_ID
  fi

  if [[ -z "${MACHINE_SECRET}" ]]; then
    echo -n "Enter Machine Secret (hidden): "
    read -s -r MACHINE_SECRET
    echo ""
  fi

  if [[ -z "${MACHINE_ID}" || -z "${MACHINE_SECRET}" ]]; then
    log_error "Machine ID and Machine Secret are required."
    exit 1
  fi
}

OS_NAME="$(uname -s)"
IS_MACOS=false
IS_LINUX=false
case "${OS_NAME}" in
  Darwin)
    IS_MACOS=true
    ;;
  Linux)
    IS_LINUX=true
    ;;
  *)
    log_error "Unsupported operating system: ${OS_NAME}. This script supports Ubuntu/Linux and macOS."
    exit 1
    ;;
esac

# Parse parameters
IMAGE=""
PORT="3000"
CONTAINER_NAME="carwash-smartgw"
MACHINE_ID=""
MACHINE_SECRET=""
SERVER_API_BASE_URL="https://carwash-api.vn01.zodinet.tech"
APP_DIR=""
CONTAINER_APP_DIR="/usr/src/app"
SERIAL_PORT="/dev/ttyUSB0"
MOUNT_ALL_DEV=false
REGISTRY_USER=""
REGISTRY_PASS=""
POLL_INTERVAL="3600"
STOP_TIMEOUT="60"
PRE_ROLLOUT_URL=""
PRE_ROLLOUT_TIMEOUT="300"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --container)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --machine-id)
      MACHINE_ID="$2"
      shift 2
      ;;
    --machine-secret)
      MACHINE_SECRET="$2"
      shift 2
      ;;
    --server-api-base-url)
      SERVER_API_BASE_URL="$2"
      shift 2
      ;;
    --app-dir)
      APP_DIR="$2"
      shift 2
      ;;
    --serial-port | --serial-device)
      SERIAL_PORT="$2"
      shift 2
      ;;
    --username)
      REGISTRY_USER="$2"
      shift 2
      ;;
    --password)
      REGISTRY_PASS="$2"
      shift 2
      ;;
    --interval)
      POLL_INTERVAL="$2"
      shift 2
      ;;
    --stop-timeout)
      STOP_TIMEOUT="$2"
      shift 2
      ;;
    --pre-rollout-url)
      PRE_ROLLOUT_URL="$2"
      shift 2
      ;;
    --pre-rollout-timeout)
      PRE_ROLLOUT_TIMEOUT="$2"
      shift 2
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

# "all" selects the passthrough mode, not a port the app can open, so keep the
# default path for SERIAL_PORT in that case.
if [[ "${SERIAL_PORT}" == "all" || "${SERIAL_PORT}" == "/dev" ]]; then
  MOUNT_ALL_DEV=true
  SERIAL_PORT="/dev/ttyUSB0"
fi

function wait_for_pre_rollout_url() {
  if [[ -z "${PRE_ROLLOUT_URL}" ]]; then
    return 0
  fi

  if ! command_exists curl; then
    log_error "curl is required for --pre-rollout-url checks."
    exit 1
  fi

  local deadline
  deadline=$((SECONDS + PRE_ROLLOUT_TIMEOUT))

  log_info "Waiting for pre-rollout check to pass: ${PRE_ROLLOUT_URL}"
  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    if curl -fsS --max-time 5 "${PRE_ROLLOUT_URL}" >/dev/null; then
      log_info "Pre-rollout check passed."
      return 0
    fi

    sleep 5
  done

  log_error "Pre-rollout check did not pass within ${PRE_ROLLOUT_TIMEOUT} seconds. Aborting rollout."
  exit 1
}

function explain_docker_runtime_failure() {
  local error_file="$1"

  if grep -qE 'error creating device nodes|create device inode /dev/pts|openat .* permission denied' "${error_file}"; then
    log_error "Docker failed while creating container device nodes."
    log_error "This is usually a host/container-runtime issue, not an application image issue."
    log_error "Common causes: running Docker inside an unprivileged LXC/OpenVZ container, rootless Docker without required device permissions, or a VPS provider that blocks mknod/devpts."
    log_error "Run this on a VM/bare-metal host with full Docker support, or enable nested/privileged Docker support on the host."
    log_error "For Proxmox LXC, check host-side settings such as nesting/keyctl and whether the container is privileged enough for Docker."
  fi
}

function run_docker_with_diagnostics() {
  local error_file
  error_file="$(mktemp)"

  if "$@" 2> >(tee "${error_file}" >&2); then
    rm -f "${error_file}"
    return 0
  fi

  explain_docker_runtime_failure "${error_file}"
  rm -f "${error_file}"
  return 1
}

# Prompt for image if not provided
if [[ -z "${IMAGE}" ]]; then
  echo -n "Enter the Docker image name (e.g. zodinet/carwash-smartgw:latest or registry.example.com/project/app:tag): "
  read -r IMAGE
  if [[ -z "${IMAGE}" ]]; then
    log_error "Docker image name is required."
    exit 1
  fi
fi

# Derive the registry host from the image reference. Docker treats the first
# path component as a registry host only when it contains a dot/colon or is
# "localhost"; otherwise the image lives on Docker Hub.
REGISTRY_HOST=""
IMAGE_FIRST_PART="${IMAGE%%/*}"
if [[ "${IMAGE}" == */* ]] &&
  [[ "${IMAGE_FIRST_PART}" == *.* || "${IMAGE_FIRST_PART}" == *:* || "${IMAGE_FIRST_PART}" == "localhost" ]]; then
  REGISTRY_HOST="${IMAGE_FIRST_PART}"
fi
REGISTRY_LABEL="${REGISTRY_HOST:-Docker Hub}"
# Watchtower reads a plain config.json; Docker Hub is keyed by its legacy URL.
WATCHTOWER_AUTH_KEY="${REGISTRY_HOST:-https://index.docker.io/v1/}"

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

if [[ "${IS_MACOS}" == true && "${EUID}" -eq 0 ]]; then
  log_error "Do not run this script with sudo on macOS. Docker Desktop and bind mounts should run as your normal user."
  log_error "If ${APP_DIR} is already owned by root, fix it with: sudo chown -R ${SUDO_USER:-$(id -un)}:staff ${APP_DIR}"
  exit 1
fi

# Step 1: Verify Docker installation
log_info "Checking Docker installation..."
if ! command_exists docker; then
  log_warn "Docker is not installed."
  if [[ "${IS_MACOS}" == true ]]; then
    log_error "Install Docker Desktop for Mac and start it, then run this script again: https://www.docker.com/products/docker-desktop/"
    exit 1
  fi

  if confirm "Would you like to install Docker now?"; then
    if [[ "${EUID}" -ne 0 ]]; then
      log_error "Installing Docker on Linux requires root. Please re-run with sudo."
      exit 1
    fi
    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    if command_exists systemctl; then
      systemctl enable --now docker
    elif command_exists service; then
      service docker start
    fi
  else
    log_error "Docker is required to continue. Exiting."
    exit 1
  fi
fi

# Ensure docker is running
if ! docker info >/dev/null 2>&1; then
  if [[ "${IS_MACOS}" == true ]]; then
    log_error "Docker Desktop is not running or this user cannot access Docker. Start Docker Desktop, then run this script again."
    exit 1
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    log_error "Cannot access Docker. On Ubuntu, run with sudo or add this user to the docker group and log in again."
    exit 1
  fi

  log_info "Starting Docker daemon..."
  if command_exists systemctl; then
    systemctl start docker
  elif command_exists service; then
    service docker start
  else
    log_error "Could not start Docker automatically. Please start Docker and run this script again."
    exit 1
  fi
fi

# Step 2: Authenticate to the container registry
log_info "Authenticating with ${REGISTRY_LABEL}..."
# Check if already authenticated or prompt
DOCKER_CONFIG_DIR="${DOCKER_CONFIG:-${HOME:-/root}/.docker}"
DOCKER_CONFIG_PATH="${DOCKER_CONFIG_DIR}/config.json"

if [[ ! -f "${DOCKER_CONFIG_PATH}" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  SUDO_USER_HOME=""
  if command_exists getent; then
    SUDO_USER_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6 || true)"
  fi
  if [[ -z "${SUDO_USER_HOME}" && -d "/Users/${SUDO_USER}" ]]; then
    SUDO_USER_HOME="/Users/${SUDO_USER}"
  elif [[ -z "${SUDO_USER_HOME}" && -d "/home/${SUDO_USER}" ]]; then
    SUDO_USER_HOME="/home/${SUDO_USER}"
  fi

  SUDO_DOCKER_CONFIG_PATH="${SUDO_USER_HOME}/.docker/config.json"
  if [[ -n "${SUDO_USER_HOME}" && -f "${SUDO_DOCKER_CONFIG_PATH}" ]]; then
    DOCKER_CONFIG_PATH="${SUDO_DOCKER_CONFIG_PATH}"
    log_info "Using Docker credentials from ${DOCKER_CONFIG_PATH}."
  fi
fi

DOCKER_CONFIG_USES_HELPER=false
if [[ -f "${DOCKER_CONFIG_PATH}" ]] && grep -Eq '"credsStore"|"credHelpers"' "${DOCKER_CONFIG_PATH}"; then
  DOCKER_CONFIG_USES_HELPER=true
fi

if [[ "${DOCKER_CONFIG_USES_HELPER}" == true ]]; then
  log_warn "Docker config uses a credential helper. Docker can pull with it, but Watchtower cannot use that helper inside its container."
  log_warn "Provide ${REGISTRY_LABEL} credentials/token when prompted to create a Watchtower-compatible auth file."
elif [[ -s "${DOCKER_CONFIG_PATH}" ]] && grep -q "auths" "${DOCKER_CONFIG_PATH}"; then
  log_info "Found existing Docker login credentials."
  if ! confirm "Would you like to re-authenticate with ${REGISTRY_LABEL}?"; then
    # Skip credentials prompt
    REGISTRY_USER="skipped"
  fi
fi

if [[ "${REGISTRY_USER}" != "skipped" ]]; then
  if [[ -z "${REGISTRY_USER}" ]]; then
    echo -n "Enter ${REGISTRY_LABEL} Username: "
    read -r REGISTRY_USER
  fi
  if [[ -z "${REGISTRY_PASS}" ]]; then
    echo -n "Enter ${REGISTRY_LABEL} Password or Access Token (hidden): "
    read -s -r REGISTRY_PASS
    echo ""
  fi

  if [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]]; then
    log_info "Logging in to ${REGISTRY_LABEL}..."
    LOGIN_OK=false
    if [[ -n "${REGISTRY_HOST}" ]]; then
      if echo "${REGISTRY_PASS}" | docker login "${REGISTRY_HOST}" --username "${REGISTRY_USER}" --password-stdin; then
        LOGIN_OK=true
      fi
    else
      if echo "${REGISTRY_PASS}" | docker login --username "${REGISTRY_USER}" --password-stdin; then
        LOGIN_OK=true
      fi
    fi
    if [[ "${LOGIN_OK}" == true ]]; then
      DOCKER_CONFIG_PATH="${DOCKER_CONFIG:-${HOME:-/root}/.docker}/config.json"
      log_info "Successfully authenticated with ${REGISTRY_LABEL}."
    else
      log_error "Docker login to ${REGISTRY_LABEL} failed. Please run the script again with correct credentials."
      exit 1
    fi
  else
    log_warn "Docker login skipped. Pushing/pulling private images might fail if unauthenticated."
  fi
fi

# Step 3: Setup host directories and .env config
log_info "Setting up configuration directory at ${APP_DIR}..."
if [[ -e "${APP_DIR}" && ! -w "${APP_DIR}" ]]; then
  log_error "Cannot write to ${APP_DIR}."
  if [[ "${IS_MACOS}" == true ]]; then
    log_error "This usually means it was created with sudo. Fix it with: sudo chown -R $(id -un):staff ${APP_DIR}"
  else
    log_error "Re-run with sudo or choose a writable directory with --app-dir."
  fi
  exit 1
fi

if ! mkdir -p "${APP_DIR}"; then
  log_error "Could not create ${APP_DIR}. Re-run with sudo or choose a writable directory with --app-dir."
  exit 1
fi
if ! chmod 700 "${APP_DIR}"; then
  log_error "Could not set permissions on ${APP_DIR}. Re-run with sudo or choose a writable directory with --app-dir."
  exit 1
fi

ENV_FILE="${APP_DIR}/.env"
CONTAINER_ENV_FILE="${CONTAINER_APP_DIR}/.env"
# Everything the gateway needs is written below, so a fresh install needs no
# hand-edited .env. Any extra keys already in the file are left untouched, which
# is how you keep a manual override across re-runs.
if [[ ! -f "${ENV_FILE}" ]]; then
  touch "${ENV_FILE}"
fi

prompt_machine_credentials
upsert_env_value "MACHINE_ID" "${MACHINE_ID}" "${ENV_FILE}"
upsert_env_value "MACHINE_SECRET" "${MACHINE_SECRET}" "${ENV_FILE}"
upsert_env_value "SERVER_API_BASE_URL" "${SERVER_API_BASE_URL}" "${ENV_FILE}"
upsert_env_value "SERIAL_PORT" "${SERIAL_PORT}" "${ENV_FILE}"
# MQTT_URL is left unset so broker settings are auto-fetched from
# SERVER_API_BASE_URL, and MQTT defaults to enabled only when MQTT_URL is set --
# so it has to be turned on explicitly here.
upsert_env_value "MQTT_ENABLED" "true" "${ENV_FILE}"
# The container port is fixed to 3000 by the -p mapping below; a stray PORT
# value would make the app listen where nothing is mapped.
upsert_env_value "PORT" "3000" "${ENV_FILE}"
log_info "Wrote MACHINE_ID, MACHINE_SECRET, SERVER_API_BASE_URL, SERIAL_PORT, MQTT_ENABLED and PORT to ${ENV_FILE}."
log_info "All other settings fall back to the defaults in src/config/gateway.config.ts."

if grep -qEi '^SERIAL_SIMULATOR_ENABLED=(true|1|yes|on)[[:space:]]*$' "${ENV_FILE}"; then
  log_warn "SERIAL_SIMULATOR_ENABLED is enabled in ${ENV_FILE}."
  log_warn "The gateway will use the in-process board simulator and will NOT talk to the real wash machine."
  log_warn "Set SERIAL_SIMULATOR_ENABLED=false for a production device."
fi
log_info "The env file will be mounted inside the container at ${CONTAINER_ENV_FILE}."
chmod 600 "${ENV_FILE}"

WATCHTOWER_DOCKER_CONFIG_PATH="${DOCKER_CONFIG_PATH}"
if [[ "${REGISTRY_USER}" != "skipped" && -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]]; then
  WATCHTOWER_DOCKER_CONFIG_PATH="${APP_DIR}/watchtower-docker-config.json"
  DOCKER_AUTH="$(printf "%s:%s" "${REGISTRY_USER}" "${REGISTRY_PASS}" | base64 | tr -d '\n')"
  cat > "${WATCHTOWER_DOCKER_CONFIG_PATH}" <<EOF
{"auths":{"${WATCHTOWER_AUTH_KEY}":{"auth":"${DOCKER_AUTH}"}}}
EOF
  chmod 600 "${WATCHTOWER_DOCKER_CONFIG_PATH}"
  log_info "Created Watchtower auth config for ${REGISTRY_LABEL} at ${WATCHTOWER_DOCKER_CONFIG_PATH}."
elif [[ "${DOCKER_CONFIG_USES_HELPER}" == true ]]; then
  log_warn "Watchtower will run without usable private registry credentials."
  log_warn "Re-run with --username and --password/token if ${IMAGE} is private."
fi

# Step 4: Deploy the application container
log_info "Deploying application container: ${CONTAINER_NAME}..."

# Pull the latest image first to ensure credentials work and image is available
log_info "Pulling image ${IMAGE}..."
docker pull "${IMAGE}"

# Stop and clean up existing app container
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  log_warn "Existing container ${CONTAINER_NAME} found. Stopping and removing..."
  wait_for_pre_rollout_url
  docker stop "${CONTAINER_NAME}" || true
  docker rm -f "${CONTAINER_NAME}" || true
fi

# Run application container
log_info "Starting application container on port ${PORT}..."
# SERIAL_PORT is already in the env file; these args only handle host passthrough.
DOCKER_DEVICE_ARGS=()
if [[ "${MOUNT_ALL_DEV}" == true ]]; then
  log_info "Mounting entire /dev directory to container to share all serial ports."
  DOCKER_DEVICE_ARGS=(-v /dev:/dev)
elif [[ -e "${SERIAL_PORT}" ]]; then
  DOCKER_DEVICE_ARGS=(--device "${SERIAL_PORT}:${SERIAL_PORT}")
else
  log_warn "Serial device ${SERIAL_PORT} was not found. Starting without USB RS-485 passthrough."
fi

# The ${arr[@]+"${arr[@]}"} form keeps set -u happy on macOS bash 3.2,
# where expanding an empty array is treated as an unbound variable.
run_docker_with_diagnostics docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart always \
  -p "${PORT}:3000" \
  ${DOCKER_DEVICE_ARGS[@]+"${DOCKER_DEVICE_ARGS[@]}"} \
  --env-file "${ENV_FILE}" \
  -v "${ENV_FILE}:${CONTAINER_ENV_FILE}:ro" \
  --stop-timeout "${STOP_TIMEOUT}" \
  --label 'com.centurylinklabs.watchtower.enable=true' \
  --label "com.centurylinklabs.watchtower.scope=${CONTAINER_NAME}" \
  --log-driver local \
  --privileged \
  "${IMAGE}"

# Step 5: Deploy Watchtower for automatic updates
WATCHTOWER_CONTAINER="watchtower-${CONTAINER_NAME}"
log_info "Deploying Watchtower container: ${WATCHTOWER_CONTAINER}..."

# Stop and clean up existing Watchtower container for this app
if docker ps -a --format '{{.Names}}' | grep -q "^${WATCHTOWER_CONTAINER}$"; then
  log_warn "Existing Watchtower container ${WATCHTOWER_CONTAINER} found. Removing..."
  docker stop "${WATCHTOWER_CONTAINER}" || true
  docker rm -f "${WATCHTOWER_CONTAINER}" || true
fi

# Run Watchtower container. If Docker credentials are available, mount the config
# file so Watchtower can authenticate with private Docker Hub repositories.
WATCHTOWER_AUTH_MOUNT=()
WATCHTOWER_RUN_ONCE_AUTH_ARG=""
if [[ -f "${WATCHTOWER_DOCKER_CONFIG_PATH}" ]]; then
  WATCHTOWER_AUTH_MOUNT=(-v "${WATCHTOWER_DOCKER_CONFIG_PATH}:/config.json:ro")
  WATCHTOWER_RUN_ONCE_AUTH_ARG="-v ${WATCHTOWER_DOCKER_CONFIG_PATH}:/config.json:ro"
else
  log_warn "Docker config file not found at ${WATCHTOWER_DOCKER_CONFIG_PATH}; Watchtower will run without registry credentials."
fi

run_docker_with_diagnostics docker run -d \
  --name "${WATCHTOWER_CONTAINER}" \
  --restart always \
  -e DOCKER_API_VERSION=1.40 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --label "com.centurylinklabs.watchtower.scope=${CONTAINER_NAME}" \
  ${WATCHTOWER_AUTH_MOUNT[@]+"${WATCHTOWER_AUTH_MOUNT[@]}"} \
  containrrr/watchtower \
  --cleanup \
  --label-enable \
  --scope "${CONTAINER_NAME}" \
  --interval "${POLL_INTERVAL}"

# Step 6: Verify deployment health
# Poll the app's /health endpoint rather than trusting `docker ps`: with
# --restart always a crash-looping container still reports "Up".
HEALTH_URL="http://localhost:${PORT}/health"
HEALTH_TIMEOUT=60
log_info "Waiting for application to become healthy at ${HEALTH_URL} (up to ${HEALTH_TIMEOUT}s)..."

APP_HEALTHY=false
if command_exists curl; then
  HEALTH_DEADLINE=$((SECONDS + HEALTH_TIMEOUT))
  while [[ "${SECONDS}" -lt "${HEALTH_DEADLINE}" ]]; do
    if curl -fsS --max-time 5 "${HEALTH_URL}" >/dev/null 2>&1; then
      APP_HEALTHY=true
      break
    fi
    sleep 3
  done
else
  log_warn "curl not found; falling back to container status check only."
  sleep 5
  if docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${CONTAINER_NAME} "; then
    APP_HEALTHY=true
  fi
fi

if [[ "${APP_HEALTHY}" == true ]]; then
  log_info "Application is up and responding on ${HEALTH_URL}!"
  docker ps --filter "name=${CONTAINER_NAME}"
else
  log_error "Application did not become healthy within ${HEALTH_TIMEOUT} seconds."
  log_error "Check docker logs: docker logs ${CONTAINER_NAME}"
  exit 1
fi

log_info "Watchtower is running and monitoring ${CONTAINER_NAME} updates."
docker ps --filter "name=${WATCHTOWER_CONTAINER}"

cat <<EOF

======================================================================
CONGRATULATIONS! Your application deployment is complete.

Application Container Name:  ${CONTAINER_NAME}
App Host Port Binding:       http://localhost:${PORT}
Watchtower Container Name:   ${WATCHTOWER_CONTAINER}
Watchtower Poll Interval:    Every ${POLL_INTERVAL} seconds
Environment file location:   ${ENV_FILE}

To check your application logs, run:
  docker logs -f ${CONTAINER_NAME}

To trigger manually a pull & update check from Watchtower, run:
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock ${WATCHTOWER_RUN_ONCE_AUTH_ARG} -e DOCKER_API_VERSION=1.40 containrrr/watchtower --cleanup --label-enable --scope ${CONTAINER_NAME} --run-once
======================================================================
EOF
