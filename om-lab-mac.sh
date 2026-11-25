#!/bin/bash
# =============================================================================
# om-lab-mac.sh
# Runs the Ops Manager 8.0 lab (setup-opsmanager-lab.sh) on a Mac with Apple's
# "container" tool: builds an Ubuntu 24.04 image with systemd for amd64
# (Rosetta), creates a 16 GB container machine, checks it, installs the lab
# inside it, and opens Ops Manager in your browser.
#
# Requirements: Apple silicon Mac, macOS 26 (15 works with limits), Rosetta,
# Apple "container" CLI, >= 24 GB of physical RAM (32 GB recommended),
# the Ops Manager 8.0.x .deb (Debian 12, 13 / Ubuntu 22.04, 24.04 · DEB).
#
# Usage (run on the Mac, as your normal user, NOT with sudo):
#   bash om-lab-mac.sh            # all steps: check, image, machine, install, open
#   bash om-lab-mac.sh check      # only check the Mac and (if it exists) the machine
#   bash om-lab-mac.sh status     # machine + lab status
#   bash om-lab-mac.sh start      # boot the machine, start the lab, fix the URL
#   bash om-lab-mac.sh stop       # stop the lab, then the machine (frees the RAM)
#   bash om-lab-mac.sh open       # open Ops Manager in the browser
#   bash om-lab-mac.sh shell      # shell inside the machine
#   bash om-lab-mac.sh delete     # delete the machine (and with IMAGE=1 the image)
#
# Optional variables (put them before the command):
#   OM_DEB=~/Downloads/mongodb-mms-8.0.x.deb   Ops Manager package
#                    (default: newest mongodb-mms*.deb in ~/om-lab, ~/Downloads, .)
#   MACHINE=om-lab           machine name
#   MACHINE_MEMORY=16G       machine memory (the lab needs >= 15 GB inside)
#   MACHINE_CPUS=4           machine vCPUs
#   IMAGE_TAG=local/om-lab-ubuntu:24.04   image name
#   WORK_DIR=~/om-lab        folder shared with the machine (scripts + .deb)
#   REBUILD=1                rebuild the image even if it exists
#   FORCE_RAM=1              continue even if the Mac has less than 24 GB
#   APPDB_PWD=... OM_ADMIN_PWD=...  passwords (else the lab asks inside)
#   OPEN_BROWSER=0           do not open the browser at the end
#   DNS_SERVERS="10.1.2.3"   DNS server(s) for the image build and the machine
#                    (default: auto. Tries the container default, then the Mac's
#                    DNS servers, then 1.1.1.1 and 8.8.8.8)
# Any other lab variable (OM_HEAP_MB, APPDB_CACHE_GB, MONGO_VERSION, ...) is
# passed to setup-opsmanager-lab.sh.
# =============================================================================
set -euo pipefail

MACHINE=${MACHINE:-om-lab}
MACHINE_MEMORY=${MACHINE_MEMORY:-16G}
MACHINE_CPUS=${MACHINE_CPUS:-4}
IMAGE_TAG=${IMAGE_TAG:-local/om-lab-ubuntu:24.04}
WORK_DIR=${WORK_DIR:-$HOME/om-lab}
OPEN_BROWSER=${OPEN_BROWSER:-1}
LAB_SCRIPT=setup-opsmanager-lab.sh
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ENVF=""
LAB_DNS=""            # chosen DNS server(s), empty = container default works
PROBE_IMAGE=ubuntu:24.04
PROBE_HOST=archive.ubuntu.com
LAB_PASS_VARS="APPDB_PWD OM_ADMIN_PWD OM_ADMIN_USER OM_HEAP_MB DAEMON_HEAP_MB APPDB_CACHE_GB MONGO_VERSION MONGOSH_VERSION CREATE_OM_USER OM_WAIT_MIN OM_URL LOW_RAM"

# ------------------------------------------------------------------ helpers
log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

ask_yes() { # ask_yes "question" -> 0 if yes
  local a; read -rp "    $1 [y/N] " a
  [[ $a == y || $a == Y || $a == yes || $a == s || $a == S ]]
}

m_run()  { container machine run -n "$MACHINE" -- "$@"; }          # as your user
m_root() { container machine run -n "$MACHINE" --root -- "$@"; }   # as root
machine_exists() { container machine inspect "$MACHINE" >/dev/null 2>&1; }
image_exists()   { container image inspect "$IMAGE_TAG" >/dev/null 2>&1; }
lab_installed()  { m_root test -f /etc/mongodb-om-lab/lab.env >/dev/null 2>&1; }
lab_path()       { echo "$WORK_DIR/$LAB_SCRIPT"; }
machine_ip()     { m_run sh -c "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '\r'; }

mem_to_mb() { # 16G / 16384M / 16g -> MB
  local v; v=$(echo "$1" | tr '[:lower:]' '[:upper:]')
  case $v in
    *G) echo $(( ${v%G} * 1024 )) ;;
    *M) echo "${v%M}" ;;
    *) die "MACHINE_MEMORY must look like 16G or 16384M (got $1)" ;;
  esac
}

# -------------------------------------------------------------------- steps
check_mac() {
  log "Step 1/7 · Checking the Mac"
  [[ $(uname -s) == Darwin ]] || die "Run this on macOS. On Linux run: sudo bash $LAB_SCRIPT"
  [[ $EUID -ne 0 ]] || die "Do not use sudo: run it as your normal user (bash $0)."
  [[ $(uname -m) == arm64 ]] || die "Apple container needs an Apple silicon Mac (this one is $(uname -m))."

  local ver major; ver=$(sw_vers -productVersion); major=${ver%%.*}
  if (( major >= 26 )); then info "macOS $ver"
  elif (( major == 15 )); then warn "macOS $ver: container works, but several features need macOS 26."
  else die "macOS $ver is too old. Use macOS 26 (or at least 15)."
  fi

  local ram_gb want_mb; ram_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
  want_mb=$(mem_to_mb "$MACHINE_MEMORY")
  info "Physical RAM: ${ram_gb} GB · machine: $MACHINE_MEMORY, $MACHINE_CPUS vCPUs"
  if (( ram_gb * 1024 < want_mb + 8 * 1024 )); then
    [[ ${FORCE_RAM:-0} == 1 ]] || die "The machine takes $MACHINE_MEMORY and macOS needs ~8 GB more: this Mac has ${ram_gb} GB.
Use a Mac with >= 24 GB (32 GB recommended), or run anyway with FORCE_RAM=1.
On a 16 GB Mac you can try the reduced profile: MACHINE_MEMORY=8G LOW_RAM=1 bash $0"
    warn "Continuing with FORCE_RAM=1: macOS may swap heavily."
  elif (( ram_gb < 32 )); then
    warn "${ram_gb} GB works but is tight. Close other apps while the lab runs."
  fi

  if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
    warn "Rosetta is not installed (needed to run x86_64 Linux)."
    ask_yes "Install Rosetta now (softwareupdate --install-rosetta)?" || die "Rosetta is required."
    softwareupdate --install-rosetta --agree-to-license
  fi
  info "Rosetta: installed"

  if ! command -v container >/dev/null 2>&1; then
    warn "Apple 'container' CLI not found."
    if command -v brew >/dev/null 2>&1 && ask_yes "Install it with Homebrew (brew install container)?"; then
      brew install container
    else
      die "Install it from https://github.com/apple/container/releases (signed .pkg) or with: brew install container"
    fi
  fi
  info "container: $(container --version 2>/dev/null | head -n 1)"
}

start_services() {
  log "Step 2/7 · Starting the container services"
  if container system status >/dev/null 2>&1; then
    info "Already running"
  else
    container system start --enable-kernel-install
  fi
  choose_dns
}

prepare_files() {
  log "Step 3/7 · Preparing $WORK_DIR (shared with the machine)"
  [[ $WORK_DIR == "$HOME"/* ]] || die "WORK_DIR must be inside your home folder ($HOME): only the home folder is mounted in the machine."
  mkdir -p "$WORK_DIR"
  [[ -f $SCRIPT_DIR/$LAB_SCRIPT ]] || die "$LAB_SCRIPT must be next to $(basename "$0") ($SCRIPT_DIR)."
  if [[ $SCRIPT_DIR != "$WORK_DIR" ]]; then cp -f "$SCRIPT_DIR/$LAB_SCRIPT" "$WORK_DIR/"; fi
  info "$(lab_path)"

  if [[ -z ${OM_DEB:-} && -z ${OM_URL:-} ]]; then
    # Ops Manager is mongodb-mms-<version>...deb; mongodb-mms-automation-agent* is the MongoDB Agent
    OM_DEB=$(ls -1 "$WORK_DIR"/mongodb-mms-[0-9]*.deb "$HOME"/Downloads/mongodb-mms-[0-9]*.deb \
      ./mongodb-mms-[0-9]*.deb 2>/dev/null | sort -V | tail -n 1 || true)
  fi
  if [[ -n ${OM_DEB:-} ]]; then
    [[ -f $OM_DEB ]] || die "OM_DEB does not exist: $OM_DEB"
    case $(basename "$OM_DEB") in
      *automation-agent*|*mongodb-agent*) die "$(basename "$OM_DEB") is the MongoDB Agent, not Ops Manager.
$(om_download_hint)" ;;
    esac
    OM_DEB=$(cd "$(dirname "$OM_DEB")" && pwd)/$(basename "$OM_DEB")
    # Copy it next to the lab script: macOS privacy rules can hide ~/Downloads from the machine
    if [[ $(dirname "$OM_DEB") != "$WORK_DIR" ]]; then cp -f "$OM_DEB" "$WORK_DIR/"; OM_DEB=$WORK_DIR/$(basename "$OM_DEB"); fi
    case $(basename "$OM_DEB") in mongodb-mms-8.0.*) ;; *) warn "$(basename "$OM_DEB") does not look like Ops Manager 8.0.x; the lab will check it." ;; esac
    info "Ops Manager package: $OM_DEB"
  elif [[ -n ${OM_URL:-} ]]; then
    info "Ops Manager will be downloaded inside the machine from OM_URL"
  else
    local agents; agents=$(ls -1 "$WORK_DIR"/mongodb-mms-automation-agent*.deb "$HOME"/Downloads/mongodb-mms-automation-agent*.deb 2>/dev/null | head -n 1 || true)
    [[ -z $agents ]] || warn "Found $(basename "$agents"): that is the MongoDB Agent, not Ops Manager."
    die "No Ops Manager .deb found in $WORK_DIR or ~/Downloads.
$(om_download_hint)"
  fi
}

om_download_hint() {
  cat <<TXT
Download Ops Manager from https://www.mongodb.com/try/download/ops-manager
  Version 8.0.x · Platform "Debian 12, 13 / Ubuntu 22.04, 24.04" · Package DEB
The file is named like mongodb-mms-8.0.x.<build>.amd64.deb (about 1 GB).
Save it to ~/Downloads, or pass OM_DEB=/path/to/mongodb-mms-8.0.x....amd64.deb
TXT
}

# ---------------------------------------------------------------------- DNS
mac_dns_servers() { # IPv4 DNS servers macOS is using right now (no loopback)
  scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/ { print $3 }' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | awk '!seen[$0]++' || true
}

dns_flags() { # dns_flags "ip1 ip2" -> --dns ip1 --dns ip2
  local d; for d in $1; do printf -- '--dns %s ' "$d"; done
}

dns_works() { # dns_works ["ip ..."] -> 0 if a container resolves PROBE_HOST
  # shellcheck disable=SC2046
  container run --rm $(dns_flags "${1:-}") "$PROBE_IMAGE" getent hosts "$PROBE_HOST" >/dev/null 2>&1
}

choose_dns() { # sets LAB_DNS; dies if no DNS works (unless $1 = warn)
  local c cands
  if [[ -n ${DNS_SERVERS:-} ]]; then
    LAB_DNS=$(echo "$DNS_SERVERS" | tr ',' ' ')
    if dns_works "$LAB_DNS"; then info "DNS: $LAB_DNS (DNS_SERVERS) works"; return 0; fi
    [[ ${1:-} == warn ]] && { warn "DNS_SERVERS=$LAB_DNS does not resolve $PROBE_HOST from a container."; return 0; }
    die "DNS_SERVERS=$LAB_DNS does not resolve $PROBE_HOST from a container."
  fi
  info "Checking that containers can resolve $PROBE_HOST (needed by apt and the MongoDB downloads)"
  container image inspect "$PROBE_IMAGE" >/dev/null 2>&1 || container image pull "$PROBE_IMAGE" >/dev/null 2>&1 || true
  if dns_works ""; then LAB_DNS=""; info "DNS: container default works"; return 0; fi
  warn "The container default DNS does not answer. Trying other DNS servers."
  cands="$(mac_dns_servers | tr '\n' ' ') 1.1.1.1 8.8.8.8"
  for c in $cands; do
    if dns_works "$c"; then LAB_DNS=$c; info "DNS: $c works and will be used"; return 0; fi
    info "DNS: $c does not answer"
  done
  LAB_DNS=""
  local msg="No DNS server works from inside a container, so the image build and the lab cannot download anything.
Common causes: a VPN or a security agent (for example Zscaler) that does not let the
container network (192.168.64.0/24) out. Try, in this order:
  1. Disconnect the VPN or pause the agent, then run: bash $0
  2. Ask IT for an internal DNS server and run: DNS_SERVERS=<ip> bash $0
  3. Test by hand: container run --rm $PROBE_IMAGE getent hosts $PROBE_HOST"
  [[ ${1:-} == warn ]] && { warn "$msg"; return 0; }
  die "$msg"
}

restart_builder_with_dns() {
  [[ -n $LAB_DNS ]] || return 0
  info "Restarting the image builder with DNS $LAB_DNS"
  container builder stop >/dev/null 2>&1 || true
  container builder delete --force >/dev/null 2>&1 || true
  # shellcheck disable=SC2046
  container builder start $(dns_flags "$LAB_DNS")
}

machine_dns_ok() { m_run getent hosts "$PROBE_HOST" >/dev/null 2>&1; }

fix_machine_dns() { # the machine regenerates /etc/resolv.conf at boot: fix it if DNS fails
  if machine_dns_ok; then info "DNS inside: OK"; return 0; fi
  local c cands
  if [[ -n ${DNS_SERVERS:-} ]]; then cands=$(echo "$DNS_SERVERS" | tr ',' ' ')
  else cands="$LAB_DNS $(mac_dns_servers | tr '\n' ' ') 1.1.1.1 8.8.8.8"
  fi
  for c in $cands; do
    m_root sh -c "printf 'nameserver %s\n' $c > /etc/resolv.conf" >/dev/null 2>&1 || continue
    if machine_dns_ok; then info "DNS inside: fixed, using $c"; return 0; fi
  done
  warn "DNS does not work inside the machine (cannot resolve $PROBE_HOST)."
  return 1
}

write_dockerfile() {
  cat > "$WORK_DIR/Dockerfile" <<'DOCKER'
# Ubuntu 24.04 with systemd as init, for an Apple container machine (amd64)
FROM ubuntu:24.04
ENV container container
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus sudo ca-certificates curl jq openssl tzdata \
      procps iproute2 iputils-ping hostname less vim-tiny && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
RUN >/etc/machine-id
RUN mkdir -p /var/lib/dbus && >/var/lib/dbus/machine-id
RUN systemctl set-default multi-user.target
RUN systemctl mask \
      dev-hugepages.mount \
      sys-fs-fuse-connections.mount \
      systemd-update-utmp.service \
      systemd-tmpfiles-setup.service \
      console-getty.service
DOCKER
}

build_image() {
  log "Step 4/7 · Image $IMAGE_TAG (Ubuntu 24.04 + systemd, amd64)"
  if image_exists && [[ ${REBUILD:-0} != 1 ]]; then
    info "Already built (REBUILD=1 rebuilds it)"
    return
  fi
  write_dockerfile
  restart_builder_with_dns
  info "Building with Rosetta; the first build takes a few minutes"
  # shellcheck disable=SC2046
  container build --arch amd64 $(dns_flags "$LAB_DNS") -t "$IMAGE_TAG" -f "$WORK_DIR/Dockerfile" "$WORK_DIR" \
    || die "The image build failed. If the log shows 'Temporary failure resolving', DNS does not work
in the builder: run 'bash $0 check', or pass DNS_SERVERS=<ip> (see the README)."
}

create_machine() {
  log "Step 5/7 · Container machine $MACHINE"
  if machine_exists; then
    info "Already exists (bash $0 delete removes it)"
  else
    container machine create --arch amd64 --cpus "$MACHINE_CPUS" --memory "$MACHINE_MEMORY" \
      --name "$MACHINE" "$IMAGE_TAG"
  fi
  m_run true   # boots it if it is stopped
}

check_machine() {
  log "Step 6/7 · Checking the machine"
  local arch mem_mb need_mb init state disk_gb ok=1
  arch=$(m_run uname -m | tr -d '\r')
  if [[ $arch == x86_64 ]]; then info "Architecture: x86_64 (Rosetta)"
  else warn "Architecture is '$arch', not x86_64. Ops Manager and MongoDB for this lab are x86_64 only."; ok=0
  fi

  init=$(m_run ps -p 1 -o comm= 2>/dev/null | tr -d '\r ' || true)
  if [[ $init == systemd ]]; then
    state=$(m_run systemctl is-system-running --wait 2>/dev/null | tr -d '\r' || true)
    info "systemd: PID 1 · state ${state:-unknown} (running or degraded is fine)"
  else
    warn "PID 1 is '${init:-unknown}', not systemd. The lab needs systemd."; ok=0
  fi

  mem_mb=$(m_run sh -c "awk '/MemTotal/ {printf \"%d\", \$2/1024}' /proc/meminfo" | tr -d '\r')
  need_mb=15360; [[ ${LOW_RAM:-0} == 1 ]] && need_mb=6144
  if (( mem_mb >= need_mb )); then info "Memory inside: ${mem_mb} MB"
  else
    warn "Memory inside is ${mem_mb} MB; the lab needs >= ${need_mb} MB. Fix it with:"
    warn "  container machine set -n $MACHINE memory=17G && container machine stop $MACHINE"; ok=0
  fi

  disk_gb=$(m_run sh -c "df -Pk / | awk 'NR==2 {printf \"%d\", \$4/1024/1024}'" | tr -d '\r')
  if (( disk_gb >= 15 )); then info "Free disk: ${disk_gb} GB"
  else warn "Only ${disk_gb} GB free on / ; Ops Manager + MongoDB need ~10-15 GB."
  fi

  if [[ -f $(lab_path) ]]; then
    if m_run test -r "$(lab_path)"; then info "Home folder mounted: $(lab_path) is visible"
    else warn "$(lab_path) is not visible inside the machine (home mount missing?)."; ok=0
    fi
  fi
  fix_machine_dns || ok=0
  info "IP: $(machine_ip)"
  (( ok == 1 )) || die "The machine is not usable for the lab. See the warnings above.
If the architecture or systemd check fails, Rosetta cannot run this machine: use an x86_64 Linux VM instead."
}

install_lab() {
  log "Step 7/7 · Installing the lab inside the machine (setup-opsmanager-lab.sh)"
  if lab_installed; then
    info "The lab is already installed. Starting it instead."
    start_lab; return
  fi
  local v
  ENVF=$(mktemp -t om-lab-env)
  chmod 600 "$ENVF"
  trap 'rm -f "$ENVF"' EXIT   # passwords never stay on disk
  {
    echo "OMLAB_PLATFORM=apple-container"
    [[ -n ${OM_DEB:-} ]] && echo "OM_DEB=$OM_DEB"
    for v in $LAB_PASS_VARS; do
      if [[ -n ${!v:-} ]]; then printf '%s=%s\n' "$v" "${!v}"; fi
    done
  } > "$ENVF"
  info "Passwords are asked inside the machine unless APPDB_PWD / OM_ADMIN_PWD are set."
  info "Under Rosetta the first Ops Manager start can take 20-40 minutes."
  container machine run -n "$MACHINE" --root -i -t --env-file "$ENVF" -- bash "$(lab_path)" setup
  rm -f "$ENVF"; trap - EXIT
}

show_url() {
  local url; url=$(m_root bash "$(lab_path)" url 2>/dev/null | tr -d '\r' | tail -n 1 || true)
  [[ -n $url ]] || url="http://$(machine_ip):8080"
  log "Ops Manager: $url"
  info "Shell in the machine:  bash $0 shell"
  info "Stop (frees the RAM):  bash $0 stop"
  if [[ $OPEN_BROWSER == 1 ]]; then open "$url" 2>/dev/null || true; fi
}

# ----------------------------------------------------------------- commands
cmd_up() {
  check_mac
  start_services
  prepare_files
  build_image
  create_machine
  check_machine
  install_lab
  show_url
}

cmd_check() {
  check_mac
  if command -v container >/dev/null 2>&1 && container system status >/dev/null 2>&1; then
    log "Network · DNS from containers"
    choose_dns warn
  fi
  if command -v container >/dev/null 2>&1 && container system status >/dev/null 2>&1 && machine_exists; then
    check_machine
  else
    info "No machine yet: run bash $0"
  fi
}

start_lab() {
  log "Starting machine $MACHINE and the lab"
  m_run true
  fix_machine_dns || warn "Continuing: the lab can start without internet, but downloads will fail."
  container machine run -n "$MACHINE" --root -e OMLAB_PLATFORM=apple-container -- bash "$(lab_path)" start
}

cmd_start() {
  machine_exists || die "Machine $MACHINE does not exist. Run: bash $0"
  start_lab
  show_url
}

cmd_stop() {
  machine_exists || die "Machine $MACHINE does not exist."
  log "Stopping the lab and machine $MACHINE"
  m_root bash "$(lab_path)" stop || warn "Could not stop the lab cleanly; stopping the machine anyway."
  container machine stop "$MACHINE"
  info "Stopped. The data is kept; start it again with: bash $0 start"
}

cmd_status() {
  machine_exists || die "Machine $MACHINE does not exist. Run: bash $0"
  container machine ls
  m_root bash "$(lab_path)" status || true
}

cmd_shell() {
  machine_exists || die "Machine $MACHINE does not exist. Run: bash $0"
  info "Lab commands inside: sudo bash $(lab_path) status | start | stop"
  container machine run -n "$MACHINE"
}

cmd_delete() {
  machine_exists || { info "Machine $MACHINE does not exist."; return 0; }
  warn "This deletes machine $MACHINE with ALL the lab data (AppDB, Ops Manager)."
  ask_yes "Delete it?" || die "Cancelled."
  container machine rm "$MACHINE"
  if [[ ${IMAGE:-0} == 1 ]]; then container image rm "$IMAGE_TAG" || true; fi
  info "Deleted. Files in $WORK_DIR are kept."
}

usage() { sed -n '3,39p' "$0" | sed 's/^# \{0,1\}//'; }

[[ ${OMLAB_MAC_SOURCE_ONLY:-0} == 1 ]] && return 0 2>/dev/null
case ${1:-up} in
  up|setup|install) cmd_up ;;
  check)  cmd_check ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  open)   show_url ;;
  shell)  cmd_shell ;;
  delete) cmd_delete ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
