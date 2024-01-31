#!/bin/bash
# Author：zzh
# Copyright 2023 The Docker install v2ray Authors
# CONTAINER_NAME: Docker instance name for v2ray (default v2ray).
# Requires curl  installed
set -euo pipefail
#CONTAINER_NAME=v2ray
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
magenta='\033[0;35m'
cyan='\033[0;36m'
clear='\033[0m'
bg_red='\033[0;41m'
bg_green='\033[0;42m'
bg_yellow='\033[0;43m'
bg_blue='\033[0;44m'
bg_magenta='\033[0;45m'
bg_cyan='\033[0;46m'

readonly SENTRY_LOG_FILE=${SENTRY_LOG_FILE:-}

# I/O conventions for this script:
# - Ordinary status messages are printed to STDOUT
# - STDERR is only used in the event of a fatal error
# - Detailed logs are recorded to this FULL_LOG, which is preserved if an error occurred.
# - The most recent error is stored in LAST_ERROR, which is never preserved.
FULL_LOG="$(mktemp -t v2ray_logXXX)"
LAST_ERROR="$(mktemp -t v2ray_last_errorXXX)"
readonly FULL_LOG LAST_ERROR

function log_command() {
  # Direct STDOUT and STDERR to FULL_LOG, and forward STDOUT.
  # The most recent STDERR output will also be stored in LAST_ERROR.
  "$@" > >(tee -a "${FULL_LOG}") 2> >(tee -a "${FULL_LOG}" > "${LAST_ERROR}")
}

function log_error() {
  local -r ERROR_TEXT="\033[0;31m"  # red
  local -r NO_COLOR="\033[0m"
  echo -e "${ERROR_TEXT}$1${NO_COLOR}"
  echo "$1" >> "${FULL_LOG}"
}

# Pretty prints text to stdout, and also writes to sentry log file if set.
function log_start_step() {
  log_for_sentry "$@"
  local -r str="> $*"
  local -ir lineLength=47
  echo -n "${str}"
  local -ir numDots=$(( lineLength - ${#str} - 1 ))
  if (( numDots > 0 )); then
    echo -n " "
    for _ in $(seq 1 "${numDots}"); do echo -n .; done
  fi
  echo -n " "
}

# Prints $1 as the step name and runs the remainder as a command.
# STDOUT will be forwarded.  STDERR will be logged silently, and
# revealed only in the event of a fatal error.
function run_step() {
  local -r msg="$1"
  log_start_step "${msg}"
  shift 1
  if log_command "$@"; then
    echo "OK"
  else
    # Propagates the error code
    return
  fi
}

function confirm() {
  echo -n "> $1 [Y/n] "
  local RESPONSE
  read -r RESPONSE
  RESPONSE=$(echo "${RESPONSE}" | tr '[:upper:]' '[:lower:]') || return
  [[ -z "${RESPONSE}" || "${RESPONSE}" == "y" || "${RESPONSE}" == "yes" ]]
}

function command_exists {
  command -v "$@" &> /dev/null
}

function log_for_sentry() {
  if [[ -n "${SENTRY_LOG_FILE}" ]]; then
    echo "[$(date "+%Y-%m-%d@%H:%M:%S")] install_server.sh" "$@" >> "${SENTRY_LOG_FILE}"
  fi
  echo "$@" >> "${FULL_LOG}"
}

# Check to see if docker is installed.
function verify_docker_installed() {
  if command_exists docker; then
    return 0
  fi
  log_error "NOT INSTALLED"
  if ! confirm "Would you like to install Docker? This will run 'curl https://get.docker.com/ | sh'."; then
    exit 0
  fi
  if ! run_step "Installing Docker" install_docker; then
    log_error "Docker installation failed, please visit https://docs.docker.com/install for instructions."
    exit 1
  fi
  log_start_step "Verifying Docker installation"
  command_exists docker
}

function verify_docker_running() {
  local STDERR_OUTPUT
  STDERR_OUTPUT="$(docker info 2>&1 >/dev/null)"
  local -ir RET=$?
  if (( RET == 0 )); then
    return 0
  elif [[ "${STDERR_OUTPUT}" == *"Is the docker daemon running"* ]]; then
    start_docker
    return
  fi
  return "${RET}"
}

function fetch() {
  curl --silent --show-error --fail "$@"
}

function install_docker() {
  (
    # Change umask so that /usr/share/keyrings/docker-archive-keyring.gpg has the right permissions.
    # See https://github.com/Jigsaw-Code/outline-server/issues/951.
    # We do this in a subprocess so the umask for the calling process is unaffected.
    umask 0022
    fetch https://get.docker.com/ | sh
  ) >&2
}

function start_docker() {
  systemctl enable --now docker.service >&2
}

function docker_container_exists() {
  docker ps -a --format '{{.Names}}'| grep --quiet "^$1$"
}

function remove_v2ray_container() {
  remove_docker_container "${CONTAINER_NAME}"
}

function remove_docker_container() {
  docker rm -f "$1" >&2
}

function handle_docker_container_conflict() {
  local -r CONTAINER_NAME="$1"
  local -r EXIT_ON_NEGATIVE_USER_RESPONSE="$2"
  local PROMPT="The container name \"${CONTAINER_NAME}\" is already in use by another container. This may happen when running this script multiple times."
  if [[ "${EXIT_ON_NEGATIVE_USER_RESPONSE}" == 'true' ]]; then
    PROMPT="${PROMPT} We will attempt to remove the existing container and restart it. Would you like to proceed?"
  else
    PROMPT="${PROMPT} Would you like to replace this container? If you answer no, we will proceed with the remainder of the installation."
  fi
  if ! confirm "${PROMPT}"; then
    if ${EXIT_ON_NEGATIVE_USER_RESPONSE}; then
      exit 0
    fi
    return 0
  fi
  if run_step "Removing ${CONTAINER_NAME} container" "remove_${CONTAINER_NAME}_container" ; then
    log_start_step "Restarting ${CONTAINER_NAME}"
    "start_${CONTAINER_NAME}"
    return $?
  fi
  return 1
}

# Set trap which publishes error tag only if there is an error.
function finish {
  local -ir EXIT_CODE=$?
  if (( EXIT_CODE != 0 )); then
    if [[ -s "${LAST_ERROR}" ]]; then
      log_error "\nLast error: $(< "${LAST_ERROR}")" >&2
    fi
    log_error "\nSorry! Something went wrong. If you can't figure this out, please copy and paste all this output into the Outline Manager screen, and send it to us, to see if we can help you." >&2
    log_error "Full log: ${FULL_LOG}" >&2
  else
    rm "${FULL_LOG}"
  fi
  rm "${LAST_ERROR}"
}

function get_random_port {
  local -i num=0  # Init to an invalid value, to prevent "unbound variable" errors.
  until (( 1024 <= num && num < 65536)); do
    num=$(( RANDOM + (RANDOM % 2) * 32768 ));
  done;
  echo "${num}";
}

function get_ip {
    ip=$(curl -k -4 https://ipinfo.io/ip 2>/dev/null);
    echo "${ip}";
}

function get_uuid {
    uuid=$(curl -L uuid.dev 2>/dev/null);
    echo "${uuid}";
}

function try_stop_firewalld()
{
if [ $(command -v yum) ];then 
   systemctl stop firewalld  2>&1 >/dev/null
   systemctl disable firewalld	2>&1 >/dev/null
else
   ufw disable 2>&1 >/dev/null
fi
}

function join() {
  local IFS="$1"
  shift
  echo "$*"
}


function start_v2ray() {
  # TODO(fortuna): Write API_PORT to config file,
  # rather than pass in the environment.
  local -ar docker_shadowbox_flags=(
    --name "${CONTAINER_NAME}" --restart always --net host
    -v "/etc/v2ray:/etc/v2ray"
  )
  # By itself, local messes up the return code.
  local STDERR_OUTPUT
  STDERR_OUTPUT="$(docker run -d "${docker_shadowbox_flags[@]}" v2fly/v2fly-core run -c /etc/v2ray/config.json 2>&1 >/dev/null)" && return
  readonly STDERR_OUTPUT
  log_error "FAILED"
  if docker_container_exists "${CONTAINER_NAME}"; then
    handle_docker_container_conflict "${CONTAINER_NAME}" true
    return
  else
    log_error "${STDERR_OUTPUT}"
    return 1
  fi
}
function generate_config() {
if [ -d /etc/v2ray/ ]
then 
        echo "/etc/v2ray directory exist" 2>&1 >/dev/null
else    
	mkdir -p /etc/v2ray
fi
cat > /etc/v2ray/config.json <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "ip": [
                    "geoip:private"
                ],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": "9000",
            "protocol": "vmess",
            "settings": {
                "clients": [
                    {
                        "id": "uuid"
                    }
                ]
            },
            "streamSettings": {
                "network": "tcp"
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
EOF
config_port=$(get_random_port)
clientid=$(get_uuid)
sed -i "s/9000/$config_port/g" /etc/v2ray/config.json
sed -i "s/uuid/$clientid/g" /etc/v2ray/config.json
}



install_v2ray() {
  local MACHINE_TYPE
  MACHINE_TYPE="$(uname -m)"
  if [[ "${MACHINE_TYPE}" != "x86_64" ]]; then
    log_error "Unsupported machine type: ${MACHINE_TYPE}. Please run this script on a x86_64 machine"
    exit 1
  fi

  # Make sure we don't leak readable files to other users.
  umask 0007

  export CONTAINER_NAME="${CONTAINER_NAME:-v2ray}"

  run_step "Verifying that Docker is installed" verify_docker_installed
  run_step "Verifying that Docker daemon is running" verify_docker_running
  run_step "generate_config" generate_config
  run_step "start_v2ray" start_v2ray
 
} # end of install_shadowbox

function message {
cat > /etc/v2ray/output.log <<EOF
{"v":2,"ps":"zzh-tcp-ipaddress","add":"ipaddress","port":"rundomport","id":"clientid","aid":"0","net":"tcp","type":"none","path":""}
EOF
ipaddress=$(get_ip)
clientid=$(grep -Po '"id": *\K"[^"]*"' /etc/v2ray/config.json|awk -F "\"" '{print $2}')
port=$(grep -Po '"port": *\K"[^"]*"' /etc/v2ray/config.json|awk -F "\"" '{print $2}')
protocol=$(grep -Po '"protocol": *\K"[^"]*"' /etc/v2ray/config.json|awk -F "\"" '{print $2}'|head -1)
sed -i "s/ipaddress/$ipaddress/g" /etc/v2ray/output.log
sed -i "s/clientid/$clientid/g" /etc/v2ray/output.log
sed -i "s/rundomport/$port/g" /etc/v2ray/output.log
connstr=$(cat /etc/v2ray/output.log|base64 -w0)
echo -e "v2ray使用协议: ${green}$protocol${clear}"
echo -e "v2ray连接的IP: ${green}$ipaddress${clear}"
echo -e "v2ray连接端口: ${green}$port${clear}"
echo -e "v2ray客户端id: ${green}$clientid${clear}"
echo -e "v2ray连接地址: ${green}$protocol://$connstr${clear}"
}


function main() {
  install_v2ray
  message
  try_stop_firewalld
}

main "$@"
