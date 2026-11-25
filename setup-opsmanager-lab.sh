#!/usr/bin/env bash
# =============================================================================
# setup-opsmanager-lab.sh
# Lab: Ops Manager 8.0 + its Application Database (AppDB) as a 3-member
# replica set (appdbRS), everything on ONE server with 16 GB of RAM.
# Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 (x86_64) · keyfile · systemd
#
# 16 GB profile (default):  Ops Manager heap 8096 MB (OM default)
#                           Backup Daemon heap 1024 MB
#                           AppDB 3 x cacheSizeGB=0.5   -> ~13 GB in use
# Needs >= 15 GB reported by the system (a "16 GB" VM shows ~15.6 GB).
#
# On a Mac: do not run this directly. Run om-lab-mac.sh on the Mac; it creates
# an Apple container machine (Ubuntu 24.04, amd64 via Rosetta, 16 GB) and runs
# this script inside it. The script detects the container machine by itself.
#
# Usage:
#   sudo bash setup-opsmanager-lab.sh          # install and configure everything
#   sudo bash setup-opsmanager-lab.sh status   # status of every process
#   sudo bash setup-opsmanager-lab.sh stop     # stop in order (OM -> AppDB)
#   sudo bash setup-opsmanager-lab.sh start    # start in order (AppDB -> OM)
#   sudo bash setup-opsmanager-lab.sh reset    # DELETES the lab and Ops Manager
#   sudo bash setup-opsmanager-lab.sh url      # show mms.centralUrl
#   sudo bash setup-opsmanager-lab.sh set-url [HOST]  # change it (default: this host's IP)
#
# Optional variables (put them before the command):
#   OM_DEB=/path/mongodb-mms-8.0.x...deb   Ops Manager package already on disk
#   OM_URL=https://downloads.mongodb.com/on-prem-mms/deb/...deb   or download it
#                     (if neither is set, looks for mongodb-mms-<version>*.deb in ., ~ and /root)
#   MONGO_VERSION=8.0.38   AppDB version (8.0.x only; auto: newest 8.0.x)
#   APPDB_CACHE_GB=0.5     WiredTiger cache per AppDB member
#   OM_HEAP_MB=8096        Ops Manager app heap (do not go below 8096 in production)
#   DAEMON_HEAP_MB=1024    Backup Daemon heap
#   LOW_RAM=1              allow the old 7 GB lab profile (below the OM minimum)
#   APPDB_PWD=...          password for mongoadmin (AppDB root user; else prompted)
#   OM_ADMIN_USER=omadmin  first Ops Manager user (Global Owner)
#   OM_ADMIN_PWD=...       its password (else prompted)
#   OM_HOST=$(hostname -f) host name used in mms.centralUrl
#   CREATE_OM_USER=0       skip creating the first user/org/project via the API
#   OM_WAIT_MIN=20         minutes to wait for Ops Manager (40 on Apple container)
# Example: sudo OM_DEB=~/mongodb-mms-8.0.28.deb bash setup-opsmanager-lab.sh
# =============================================================================
set -euo pipefail

CONF_DIR=/etc/mongodb-om-lab
DATA_DIR=/data/om-appdb
LOG_DIR=/var/log/mongodb
UNIT_DIR=/etc/systemd/system
BIN_ROOT=/opt/mongodb-appdb
KEYFILE=$CONF_DIR/keyfile
STATE=$CONF_DIR/lab.env
API_ENV=$CONF_DIR/om-api.env
OM_HOME=/opt/mongodb/mms
OM_PROPS=$OM_HOME/conf/conf-mms.properties
OM_MMSCONF=$OM_HOME/conf/mms.conf
OM_PORT=8080
OM_LOCAL=http://127.0.0.1:$OM_PORT
RS_NAME=appdbRS
APPDB_ADMIN_USER=mongoadmin
OM_ADMIN_USER=${OM_ADMIN_USER:-omadmin}
CREATE_OM_USER=${CREATE_OM_USER:-1}
MONGO_FALLBACK=8.0.38           # newest 8.0.x seen in the Download Center
MONGOSH_VERSION=${MONGOSH_VERSION:-2.14.3}
MEMBERS=(appdb-1 appdb-2 appdb-3)
declare -A PORT=( [appdb-1]=27501 [appdb-2]=27502 [appdb-3]=27503 )

# ------------------------------------------------------------------ helpers
log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0 ${1:-}"; }

mongod_bin() { echo "$BIN_ROOT/current/bin/mongod"; }
msh() { mongosh --quiet "$@"; }

hosts_csv() { local m out=""; for m in "${MEMBERS[@]}"; do out+="${out:+,}localhost:${PORT[$m]}"; done; echo "$out"; }
members_js() {
  local m out="" n=0
  for m in "${MEMBERS[@]}"; do out+="${out:+, }{ _id: $n, host: 'localhost:${PORT[$m]}' }"; n=$((n + 1)); done
  echo "$out"
}
rs_uri() { echo "mongodb://$(hosts_csv)/admin?replicaSet=$RS_NAME"; }
detect_platform() { # Apple container machine: the macOS home is mounted under /Users
  APPLE_CONTAINER=0
  if [[ ${OMLAB_PLATFORM:-} == apple-container ]] \
     || awk '$2 ~ "^/Users(/|$)" { f = 1 } END { exit !f }' /proc/mounts 2>/dev/null; then
    APPLE_CONTAINER=1
  fi
  if [[ -z ${OM_WAIT_MIN:-} ]]; then
    if (( APPLE_CONTAINER )); then OM_WAIT_MIN=40; else OM_WAIT_MIN=20; fi
  fi
}
primary_ip() {
  local ip; ip=$(hostname -I 2>/dev/null | awk '{ print $1 }')
  [[ -n $ip ]] || ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')
  echo "${ip:-127.0.0.1}"
}
default_host() {
  if [[ -n ${OM_HOST:-} ]]; then echo "$OM_HOST"
  elif (( APPLE_CONTAINER )); then primary_ip   # the Mac reaches the machine by IP
  else hostname -f 2>/dev/null || hostname
  fi
}
daemon_heap_txt() { if [[ -n ${DAEMON_HEAP_MB:-} ]]; then echo "${DAEMON_HEAP_MB} MB"; else echo "default"; fi; }

urlenc() { # percent-encode a string for a connection string
  local LC_ALL=C s=$1 out="" c i hex
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in [a-zA-Z0-9.~_-]) out+=$c ;; *) printf -v hex '%%%02X' "'$c"; out+=$hex ;; esac
  done
  echo "$out"
}

wait_ping() { # wait for a mongod on a port
  local port=$1 timeout=${2:-90} t
  for ((t = 0; t < timeout; t++)); do
    if msh --port "$port" --eval 'db.adminCommand({ ping: 1 }).ok' >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "Nothing answers on port $port. Check: sudo tail -n 50 $LOG_DIR/appdb-*.log"
}

wait_primary() {
  local port=$1
  msh --port "$port" --eval "
    let t = 0;
    while (db.hello().primary == null) { if (++t > 120) quit(1); sleep(1000); }
    print('    PRIMARY: ' + db.hello().primary);" \
    || die "Replica set $RS_NAME did not elect a PRIMARY within 120 s."
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$OM_LOCAL$1" 2>/dev/null || true; }

load_state() {
  [[ -f $STATE ]] || die "No lab configured ($STATE does not exist). Run: sudo bash $0"
  # shellcheck disable=SC1090
  source "$STATE"
}

# -------------------------------------------------------------------- steps
choose_sizing() {
  local mem_mb; mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' "${MEMINFO:-/proc/meminfo}")
  MEM_MB=$mem_mb
  if (( mem_mb >= 15 * 1024 )); then
    PROFILE=16GB
    APPDB_CACHE_GB=${APPDB_CACHE_GB:-0.5}
    OM_HEAP_MB=${OM_HEAP_MB:-8096}         # Ops Manager default
    DAEMON_HEAP_MB=${DAEMON_HEAP_MB:-1024}
  else
    [[ ${LOW_RAM:-0} == 1 ]] || die "This script is sized for 16 GB and the system reports ~${mem_mb} MB (needs >= 15360 MB).
Check with: free -h
To run anyway with the reduced 7 GB lab profile: sudo LOW_RAM=1 bash $0"
    PROFILE=LOW_RAM
    APPDB_CACHE_GB=${APPDB_CACHE_GB:-0.25}
    DAEMON_HEAP_MB=${DAEMON_HEAP_MB:-768}
    if [[ -z ${OM_HEAP_MB:-} ]]; then
      # RAM - AppDB(3 x (cache + 350 MB)) - OS 600 - daemon(heap + 350) - JVM non-heap 700 - slack 500
      local appdb other
      appdb=$(awk -v c="$APPDB_CACHE_GB" 'BEGIN { printf "%d", 3 * (c * 1024 + 350) }')
      other=$(( 600 + DAEMON_HEAP_MB + 350 + 700 + 500 ))
      OM_HEAP_MB=$(( (mem_mb - appdb - other) / 256 * 256 ))
      (( OM_HEAP_MB > 8096 )) && OM_HEAP_MB=8096
      (( OM_HEAP_MB >= 1536 )) || die "Not enough RAM (~${mem_mb} MB) for Ops Manager + a 3-member AppDB. You need about 6 GB."
    fi
  fi
  local need
  need=$(awk -v c="$APPDB_CACHE_GB" -v h="$OM_HEAP_MB" -v d="$DAEMON_HEAP_MB" \
    'BEGIN { printf "%.1f", (3 * (c * 1024 + 350) + 600 + h + 700 + d + 350) / 1024 }')
  log "Sizing: profile $PROFILE (~$(( mem_mb / 1024 )) GB of RAM)"
  info "AppDB: 3 mongod x cacheSizeGB=$APPDB_CACHE_GB (ports ${PORT[appdb-1]}-${PORT[appdb-3]})"
  info "Ops Manager heap: ${OM_HEAP_MB} MB · Backup Daemon heap: $(daemon_heap_txt)"
  info "Estimated use: ~${need} GB"
  if [[ $PROFILE == LOW_RAM ]]; then
    warn "Lab sizing only: Ops Manager asks for 15 GB of RAM and an 8096 MB heap in production."
  fi
}

detect_target() { # tarball target for the AppDB binaries
  . /etc/os-release
  [[ $(uname -m) == x86_64 ]] || die "Only x86_64 is covered (Ops Manager deb packages are x86_64)."
  case "${ID:-}:${VERSION_ID:-}" in
    debian:12)    TARGET=debian12 ;;
    ubuntu:22.04) TARGET=ubuntu2204 ;;
    ubuntu:24.04) TARGET=ubuntu2404 ;;
    *) die "Unsupported OS: ${PRETTY_NAME:-unknown}. Use Debian 12, Ubuntu 22.04 or 24.04 (MongoDB 8.0 + Ops Manager 8.0)." ;;
  esac
}

preflight() {
  log "Checking the system"
  detect_target
  info "OS: $PRETTY_NAME -> AppDB binaries: enterprise-$TARGET"
  if (( APPLE_CONTAINER )); then
    info "Platform: Apple container machine (x86_64 through Rosetta) · IP $(primary_ip)"
    [[ $(ps -p 1 -o comm= 2>/dev/null) == systemd ]] \
      || die "systemd is not running as init (PID 1). Re-create the machine with om-lab-mac.sh."
  fi
  if [[ -d $DATA_DIR/appdb-1 && -n $(ls -A "$DATA_DIR/appdb-1" 2>/dev/null) ]]; then
    die "A lab already exists in $DATA_DIR. To start over: sudo bash $0 reset"
  fi
  if dpkg -s mongodb-mms >/dev/null 2>&1; then
    die "Ops Manager (mongodb-mms) is already installed. To start over: sudo bash $0 reset"
  fi
  # The sharded lab (12 mongod at 16 GB, ~11 GB) and this lab (~13 GB) do not fit together
  if systemctl is-active --quiet mongos-lab 2>/dev/null \
     || systemctl list-units --state=active --plain --no-legend 'mongod-lab@*' 2>/dev/null | grep -q .; then
    [[ ${IGNORE_SHARDED:-0} == 1 ]] || die "The sharded cluster lab is running and both labs do not fit in RAM.
Stop it first: sudo bash setup-sharded-lab.sh stop   (or set IGNORE_SHARDED=1)"
  fi
  local tmp_gb; tmp_gb=$(df -Pk /tmp | awk 'NR==2 {printf "%d", $4/1024/1024}')
  (( tmp_gb >= 20 )) || warn "/tmp has ~${tmp_gb} GB free; Ops Manager warns below 20 GB (fine for a lab)."
}

install_deps() {
  log "Installing dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates jq openssl tzdata procps iproute2 libcurl4 libgssapi-krb5-2 \
    libldap-common libwrap0 libsasl2-2 libsasl2-modules libsasl2-modules-gssapi-mit liblzma5 >/dev/null
  if ! command -v mongosh >/dev/null; then
    info "mongosh not found; installing mongosh $MONGOSH_VERSION"
    local deb=/tmp/mongodb-mongosh_${MONGOSH_VERSION}_amd64.deb
    curl -fsSL -o "$deb" "https://downloads.mongodb.com/compass/mongodb-mongosh_${MONGOSH_VERSION}_amd64.deb" \
      || die "Could not download mongosh $MONGOSH_VERSION. Set MONGOSH_VERSION=<x.y.z> and run again."
    apt-get install -y -qq "$deb" >/dev/null
  fi
  info "mongosh $(mongosh --version)"
}

resolve_mongo_version() {
  if [[ -n ${MONGO_VERSION:-} ]]; then
    [[ $MONGO_VERSION =~ ^8\.0\.[0-9]+$ ]] || die "MONGO_VERSION must be 8.0.x (Ops Manager 8.0 does not support 8.2/8.3 for the AppDB)."
    return
  fi
  MONGO_VERSION=$(curl -fsSL --max-time 30 https://downloads.mongodb.org/full.json 2>/dev/null | jq -r --arg t "$TARGET" '
      .versions[] | select(.version | test("^8\\.0\\.[0-9]+$"))
      | select(any(.downloads[]?; .edition == "enterprise" and .target == $t and .arch == "x86_64"))
      | .version' 2>/dev/null | sort -V | tail -n 1 || true)
  [[ -n $MONGO_VERSION ]] || { MONGO_VERSION=$MONGO_FALLBACK; info "Could not read the version list; using $MONGO_VERSION"; }
}

install_appdb_binaries() {
  resolve_mongo_version
  local dir=$BIN_ROOT/$MONGO_VERSION
  log "AppDB binaries: MongoDB Enterprise $MONGO_VERSION (separate from any apt-installed MongoDB)"
  if [[ ! -x $dir/bin/mongod ]]; then
    local name=mongodb-linux-x86_64-enterprise-$TARGET-$MONGO_VERSION
    local url=https://downloads.mongodb.com/linux/$name.tgz
    info "Downloading $url"
    curl -fSL --progress-bar -o "/tmp/$name.tgz" "$url" || die "Download failed. Check MONGO_VERSION or the network."
    mkdir -p "$dir"
    tar -xzf "/tmp/$name.tgz" -C "$dir" --strip-components=1
    rm -f "/tmp/$name.tgz"
  fi
  ln -sfn "$dir" "$BIN_ROOT/current"
  local out rc=0
  out=$("$(mongod_bin)" --version 2>&1) || rc=$?
  if (( rc != 0 )); then
    (( rc == 132 )) && die "mongod stopped with 'Illegal instruction': this CPU (or Rosetta) does not provide AVX,
which MongoDB 5.0+ needs on x86_64. On a Mac, update macOS (Rosetta added AVX/AVX2 in macOS 15)."
    die "mongod --version failed (exit $rc): $out"
  fi
  head -n 1 <<<"$out" | sed 's/^/    /'
}

find_om_package() {
  log "Locating the Ops Manager 8.0 package"
  if [[ -n ${OM_URL:-} ]]; then
    OM_DEB=/tmp/$(basename "${OM_URL%%\?*}")
    info "Downloading $OM_URL"
    curl -fSL --progress-bar -o "$OM_DEB" "$OM_URL" || die "Could not download OM_URL."
  fi
  if [[ -z ${OM_DEB:-} ]]; then
    local home; home=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
    # mongodb-mms-<version>*.deb only: mongodb-mms-automation-agent* is the MongoDB Agent
    OM_DEB=$(ls -1 ./mongodb-mms-[0-9]*.deb "$home"/mongodb-mms-[0-9]*.deb /root/mongodb-mms-[0-9]*.deb \
      /Users/*/om-lab/mongodb-mms-[0-9]*.deb /Users/*/Downloads/mongodb-mms-[0-9]*.deb 2>/dev/null | sort -V | tail -n 1 || true)
  fi
  [[ -n ${OM_DEB:-} && -f $OM_DEB ]] || die "No Ops Manager .deb found.
Download it from https://www.mongodb.com/try/download/ops-manager
(Version 8.0.x · Platform Debian 12, 13 / Ubuntu 22.04, 24.04 · Package DEB), then run:
  sudo OM_DEB=/path/to/mongodb-mms-8.0.x.deb bash $0
or pass the copied link with OM_URL=..."
  OM_DEB=$(readlink -f "$OM_DEB")
  local pkg; pkg=$(dpkg-deb -f "$OM_DEB" Package 2>/dev/null || true)
  [[ $pkg != mongodb-mms-automation-agent* ]] || die "$(basename "$OM_DEB") is the MongoDB Agent ($pkg), not Ops Manager.
Download Ops Manager (mongodb-mms-8.0.x....amd64.deb) from https://www.mongodb.com/try/download/ops-manager"
  [[ -z $pkg || $pkg == mongodb-mms ]] || die "$(basename "$OM_DEB") is package '$pkg', not Ops Manager (mongodb-mms)."
  local ver; ver=$(dpkg-deb -f "$OM_DEB" Version 2>/dev/null || true)
  [[ $ver == 8.0.* ]] || die "Expected an Ops Manager 8.0.x package and found '${ver:-unreadable}' ($OM_DEB)."
  OM_VERSION=$ver
  info "$OM_DEB ($OM_VERSION)"
  if [[ $OM_DEB == /Users/* ]]; then   # apt's sandbox user cannot always read the macOS home mount
    mkdir -p /var/tmp/om-lab
    cp -f "$OM_DEB" /var/tmp/om-lab/
    OM_DEB=/var/tmp/om-lab/$(basename "$OM_DEB")
  fi
}

check_ports() {
  local p busy=0
  for p in "$OM_PORT" 8443 "${PORT[@]}"; do
    if ss -ltnH "sport = :$p" | grep -q .; then warn "Port $p is in use"; busy=1; fi
  done
  (( busy == 0 )) || die "Free the ports in use (sudo ss -ltnp) and run again."
}

ask_pwd() { # ask_pwd VARIABLE "label" [strict]
  local __var=$1 label=$2 strict=${3:-0} p1 p2
  if [[ -z ${!__var:-} ]]; then
    while true; do
      read -rsp "    Password for $label: " p1; echo
      read -rsp "    Confirm it: " p2; echo
      [[ $p1 == "$p2" ]] || { warn "They do not match, try again."; continue; }
      pwd_ok "$p1" "$strict" || continue
      printf -v "$__var" '%s' "$p1"; break
    done
  else
    pwd_ok "${!__var}" "$strict" || die "The password in $__var does not meet the rules."
  fi
}
pwd_ok() {
  local p=$1 strict=$2
  (( ${#p} >= 8 )) || { warn "Use at least 8 characters."; return 1; }
  if [[ $strict == 1 ]] && ! [[ $p =~ [A-Za-z] && $p =~ [0-9] && $p =~ [^A-Za-z0-9] ]]; then
    warn "Ops Manager needs at least one letter, one number and one special character."; return 1
  fi
}

ask_passwords() {
  log "Passwords (not shown; only Ops Manager's own files keep them)"
  ask_pwd APPDB_PWD "$APPDB_ADMIN_USER (AppDB root user that Ops Manager uses)"
  if [[ $CREATE_OM_USER == 1 ]]; then
    ask_pwd OM_ADMIN_PWD "$OM_ADMIN_USER (first Ops Manager user, Global Owner)" 1
  fi
  export APPDB_PWD   # mongosh reads it with process.env
}

write_appdb_files() {
  log "Creating keyfile, AppDB configs and systemd services"
  id mongodb >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin mongodb
  mkdir -p "$CONF_DIR" "$DATA_DIR" "$LOG_DIR"
  [[ -f $KEYFILE ]] || openssl rand -base64 756 > "$KEYFILE"
  chmod 400 "$KEYFILE"; chown mongodb:mongodb "$KEYFILE"

  local m
  for m in "${MEMBERS[@]}"; do
    mkdir -p "$DATA_DIR/$m"
    cat > "$CONF_DIR/$m.conf" <<CONF
storage:
  dbPath: $DATA_DIR/$m
  wiredTiger:
    engineConfig:
      cacheSizeGB: $APPDB_CACHE_GB
systemLog:
  destination: file
  path: $LOG_DIR/$m.log
  logAppend: true
net:
  port: ${PORT[$m]}
  bindIp: 127.0.0.1
replication:
  replSetName: $RS_NAME
security:
  authorization: enabled
  keyFile: $KEYFILE
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
CONF
    info "$m -> port ${PORT[$m]} ($RS_NAME)"
  done
  chown -R mongodb:mongodb "$DATA_DIR" "$LOG_DIR"

  cat > "$UNIT_DIR/appdb-lab@.service" <<UNIT
[Unit]
Description=Ops Manager lab AppDB mongod %i
After=network-online.target
Wants=network-online.target
Before=mongodb-mms.service

[Service]
User=mongodb
Group=mongodb
ExecStart=$BIN_ROOT/current/bin/mongod --config $CONF_DIR/%i.conf
Restart=on-failure
LimitFSIZE=infinity
LimitCPU=infinity
LimitAS=infinity
LimitMEMLOCK=infinity
LimitNOFILE=64000
LimitNPROC=64000
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  cat > "$STATE" <<ENV
MONGO_VERSION=$MONGO_VERSION
APPDB_CACHE_GB=$APPDB_CACHE_GB
OM_HEAP_MB=$OM_HEAP_MB
DAEMON_HEAP_MB=$DAEMON_HEAP_MB
PROFILE=$PROFILE
ENV
}

setup_appdb() {
  log "AppDB replica set ($RS_NAME, 3 members)"
  local m
  for m in "${MEMBERS[@]}"; do systemctl enable --now "appdb-lab@$m" >/dev/null; done
  for m in "${MEMBERS[@]}"; do wait_ping "${PORT[$m]}"; done
  msh --port "${PORT[appdb-1]}" --eval "rs.initiate({ _id: '$RS_NAME', members: [ $(members_js) ] }).ok" >/dev/null \
    || die "rs.initiate() failed on $RS_NAME"
  wait_primary "${PORT[appdb-1]}"
  # First user through the localhost exception
  msh "$(rs_uri)" --eval "
    db.getSiblingDB('admin').createUser({ user: '$APPDB_ADMIN_USER', pwd: process.env.APPDB_PWD,
      roles: [ { role: 'root', db: 'admin' } ] });
    print('    user $APPDB_ADMIN_USER created');" || die "Could not create $APPDB_ADMIN_USER"
  msh "$(rs_uri)" --eval "
    db.getSiblingDB('admin').auth('$APPDB_ADMIN_USER', process.env.APPDB_PWD);
    const s = rs.status().members;
    s.forEach(x => print('    ' + x.name + '  ' + x.stateStr));
    // 1 PRIMARY (1) + 2 SECONDARY (2+2) = 5
    if (s.reduce((a, v) => a + v.state, 0) !== 5) quit(1);" \
    || die "$RS_NAME is not 1 PRIMARY + 2 SECONDARY yet. Check: sudo bash $0 status"
}

install_om() {
  log "Installing Ops Manager $OM_VERSION"
  apt-get install -y -qq "$OM_DEB" >/dev/null || die "apt could not install $OM_DEB"
  [[ -f $OM_PROPS && -f $OM_MMSCONF ]] || die "Missing $OM_PROPS or $OM_MMSCONF after the install."
  systemctl stop mongodb-mms >/dev/null 2>&1 || true   # do not let it start with the default config
}

configure_om() {
  log "Configuring Ops Manager (conf-mms.properties + mms.conf)"
  local host; host=$(default_host)
  local uri="mongodb://$APPDB_ADMIN_USER:$(urlenc "$APPDB_PWD")@$(hosts_csv)/?maxPoolSize=150&replicaSet=$RS_NAME&authSource=admin"
  [[ -f $OM_PROPS.orig ]] || cp -p "$OM_PROPS" "$OM_PROPS.orig"
  umask 077
  cat > "$OM_PROPS" <<PROPS
# Written by setup-opsmanager-lab.sh (original: conf-mms.properties.orig)
mongo.mongoUri=$uri
mongo.ssl=false
mms.ignoreInitialUiSetup=true
mms.centralUrl=http://$host:$OM_PORT
mms.https.ClientCertificateMode=none
mms.adminEmailAddr=admin@om-lab.local
mms.fromEmailAddr=admin@om-lab.local
mms.replyToEmailAddr=admin@om-lab.local
mms.emailDaoClass=SIMPLE_MAILER
mms.mail.transport=smtp
mms.mail.hostname=localhost
mms.mail.port=25
mms.mail.ssl=false
mms.publicApi.whitelistEnabled=true
mms.user.invitationOnly=true
automation.versions.source=hybrid
PROPS
  umask 022
  chown mongodb-mms:mongodb-mms "$OM_PROPS" 2>/dev/null || true
  chmod 600 "$OM_PROPS"
  info "mms.centralUrl=http://$host:$OM_PORT"
  info "mongo.mongoUri -> $RS_NAME as $APPDB_ADMIN_USER (plain text, file mode 600; credentialstool can encrypt it)"

  [[ -f $OM_MMSCONF.orig ]] || cp -p "$OM_MMSCONF" "$OM_MMSCONF.orig"
  if [[ $OM_HEAP_MB != 8096 ]]; then
    sed -E -i "/^[[:space:]]*JAVA_MMS_UI_OPTS=/ s/-Xm([xs])[0-9]+[kKmMgG]?/-Xm\\1${OM_HEAP_MB}m/g" "$OM_MMSCONF"
    sed -E -i "s/^([[:space:]]*MMS_HEAP_SIZE=).*/\\1${OM_HEAP_MB}/" "$OM_MMSCONF"
  fi
  if [[ -n ${DAEMON_HEAP_MB:-} ]]; then
    sed -E -i "/^[[:space:]]*JAVA_DAEMON_OPTS=/ s/-Xm([xs])[0-9]+[kKmMgG]?/-Xm\\1${DAEMON_HEAP_MB}m/g" "$OM_MMSCONF"
  fi
  # Safety net: the JVM uses the last -Xmx/-Xms it gets, so these lines win either way
  sed -i '/# >>> om-lab heap/,/# <<< om-lab heap/d' "$OM_MMSCONF"
  {
    echo "# >>> om-lab heap (setup-opsmanager-lab.sh)"
    [[ $OM_HEAP_MB == 8096 ]] || echo "JAVA_MMS_UI_OPTS=\"\${JAVA_MMS_UI_OPTS} -Xmx${OM_HEAP_MB}m -Xms${OM_HEAP_MB}m\""
    [[ -z ${DAEMON_HEAP_MB:-} ]] || echo "JAVA_DAEMON_OPTS=\"\${JAVA_DAEMON_OPTS} -Xmx${DAEMON_HEAP_MB}m -Xms${DAEMON_HEAP_MB}m\""
    echo "# <<< om-lab heap"
  } >> "$OM_MMSCONF"
  info "Heap: Ops Manager ${OM_HEAP_MB} MB · Backup Daemon $(daemon_heap_txt) (original: mms.conf.orig)"
}

wait_om() {
  local timeout=${1:-$(( OM_WAIT_MIN * 60 ))} t code
  if (( APPLE_CONTAINER )); then
    info "The first start builds the AppDB schema; under Rosetta it can take 20-40 minutes."
  else
    info "The first start builds the AppDB schema and can take up to 15 minutes."
  fi
  info "Progress: sudo tail -f $OM_HOME/logs/mms0.log"
  for ((t = 0; t < timeout; t += 10)); do
    code=$(http_code /user/login)
    if [[ $code =~ ^[23] ]]; then info "Ops Manager answers on port $OM_PORT ($(( t / 60 )) min)"; return 0; fi
    if systemctl is-failed --quiet mongodb-mms; then
      journalctl -u mongodb-mms -n 30 --no-pager >&2 || true
      die "mongodb-mms failed. Check $OM_HOME/logs/mms0.log and mms0-startup.log"
    fi
    (( t % 60 == 0 )) && info "waiting... $(( t / 60 )) min"
    sleep 10
  done
  die "Ops Manager did not answer in $(( timeout / 60 )) min. Check: sudo tail -n 100 $OM_HOME/logs/mms0.log
If you see OutOfMemoryError, raise OM_HEAP_MB in $OM_MMSCONF"
}

start_om() {
  log "Starting Ops Manager"
  if (( APPLE_CONTAINER )); then
    # The machine IP can change after a restart: 'start' fixes mms.centralUrl first, then starts OM
    systemctl disable mongodb-mms >/dev/null 2>&1 || true
  else
    systemctl enable mongodb-mms >/dev/null 2>&1 || true
  fi
  systemctl start --no-block mongodb-mms
  wait_om
}

om_api() { # om_api METHOD PATH [JSON]  (digest auth with the saved key)
  local args=(-s --digest -u "$OM_PUB_KEY:$OM_PRIV_KEY" -H 'Content-Type: application/json' -X "$1")
  [[ -n ${3:-} ]] && args+=(--data "$3")
  curl "${args[@]}" "$OM_LOCAL/api/public/v1.0$2"
}

create_om_user() {
  [[ $CREATE_OM_USER == 1 ]] || return 0
  log "First Ops Manager user, organization and project (API)"
  local body resp org_id grp_id
  body=$(jq -n --arg u "$OM_ADMIN_USER" --arg p "$OM_ADMIN_PWD" \
    '{username: $u, password: $p, firstName: "Lab", lastName: "Admin"}')
  resp=$(curl -s -H 'Content-Type: application/json' -X POST \
    "$OM_LOCAL/api/public/v1.0/unauth/users?whitelist=127.0.0.1" --data "$body" || true)
  OM_PUB_KEY=$(jq -r '.programmaticApiKey.publicKey // empty' <<<"$resp" 2>/dev/null || true)
  OM_PRIV_KEY=$(jq -r '.programmaticApiKey.privateKey // empty' <<<"$resp" 2>/dev/null || true)
  if [[ -z $OM_PUB_KEY || -z $OM_PRIV_KEY ]]; then
    warn "Could not create the first user via the API: $(jq -r '.detail // .reason // .' <<<"$resp" 2>/dev/null | head -c 300)"
    warn "To do it in the browser: set mms.user.invitationOnly=false in $OM_PROPS,"
    warn "run 'sudo systemctl restart mongodb-mms' and use Sign Up on the login page."
    return 0
  fi
  info "user $OM_ADMIN_USER created (Global Owner)"
  org_id=$(om_api POST /orgs '{"name":"Lab Org"}' | jq -r '.id // empty' || true)
  if [[ -n $org_id ]]; then
    info "organization Lab Org ($org_id)"
    resp=$(om_api POST /groups "$(jq -n --arg o "$org_id" '{name: "Lab Project", orgId: $o}')" || true)
    grp_id=$(jq -r '.id // empty' <<<"$resp" 2>/dev/null || true)
    [[ -n $grp_id ]] && info "project Lab Project ($grp_id)" || warn "Could not create the project; create it in the UI."
  else
    warn "Could not create the organization; create it in the UI after you log in."
  fi
  umask 077
  cat > "$API_ENV" <<ENV
# Global Owner API key created by setup-opsmanager-lab.sh (lab only; keep private)
OM_URL=$OM_LOCAL
OM_PUB_KEY=$OM_PUB_KEY
OM_PRIV_KEY=$OM_PRIV_KEY
OM_ORG_ID=${org_id:-}
OM_PROJECT_ID=${grp_id:-}
OM_AGENT_API_KEY=$(jq -r '.agentApiKey // empty' <<<"${resp:-}" 2>/dev/null || true)
ENV
  umask 022
  info "API key saved to $API_ENV (root only)"
}

summary() {
  local host; host=$(sed -n 's#^mms.centralUrl=http://\([^:]*\):.*#\1#p' "$OM_PROPS" 2>/dev/null)
  [[ -n $host ]] || host=$(default_host)
  log "Done: Ops Manager $OM_VERSION + AppDB $RS_NAME (3 members, MongoDB $MONGO_VERSION)"
  cat <<TXT
    Ops Manager UI:  http://$host:$OM_PORT   (user: $OM_ADMIN_USER)
    AppDB:           mongosh "$(rs_uri)" -u $APPDB_ADMIN_USER -p
    Status:          sudo bash $0 status
    Stop/start:      sudo bash $0 stop | start
    Configs:         $CONF_DIR  ·  $OM_PROPS
    Data: $DATA_DIR   Logs: $LOG_DIR/appdb-*.log  $OM_HOME/logs/mms0.log
    Do not run the sharded lab at the same time: together they need more than 16 GB.
TXT
  if (( APPLE_CONTAINER )); then
    cat <<TXT
    Apple container: open http://$host:$OM_PORT from the Mac.
    After a machine restart use "om-lab-mac.sh start" on the Mac (it also fixes the URL if the IP changed).
TXT
  fi
}

# ----------------------------------------------------------------- commands
cmd_setup() {
  need_root
  choose_sizing
  preflight
  install_deps
  find_om_package
  check_ports
  ask_passwords
  install_appdb_binaries
  write_appdb_files
  setup_appdb
  install_om
  configure_om
  start_om
  create_om_user
  summary
}

cmd_start() {
  need_root start; load_state
  log "Starting: AppDB -> Ops Manager"
  local m
  for m in "${MEMBERS[@]}"; do systemctl start "appdb-lab@$m"; done
  for m in "${MEMBERS[@]}"; do wait_ping "${PORT[$m]}"; done
  wait_primary "${PORT[appdb-1]}"
  if (( APPLE_CONTAINER )) && [[ -z ${OM_HOST:-} ]]; then update_central_url "$(primary_ip)" || true; fi
  systemctl start --no-block mongodb-mms
  wait_om
  cmd_status
}

cmd_stop() {
  need_root stop; load_state
  log "Stopping: Ops Manager -> AppDB"
  systemctl stop mongodb-mms || true
  local m
  for m in appdb-3 appdb-2 appdb-1; do systemctl stop "appdb-lab@$m" || true; done
  info "Stopped."
}

cmd_status() {
  load_state
  log "Lab status (AppDB MongoDB $MONGO_VERSION)"
  local m st role
  printf '    %-12s %-7s %-10s %s\n' "PROCESS" "PORT" "SERVICE" "ROLE"
  for m in "${MEMBERS[@]}"; do
    st=$(systemctl is-active "appdb-lab@$m" || true)
    role=$(msh --port "${PORT[$m]}" --eval 'const h = db.hello(); print(h.isWritablePrimary ? "PRIMARY" : (h.secondary ? "SECONDARY" : "OTHER"))' 2>/dev/null || echo "--")
    printf '    %-12s %-7s %-10s %s\n' "$m" "${PORT[$m]}" "$st" "$role"
  done
  st=$(systemctl is-active mongodb-mms || true)
  printf '    %-12s %-7s %-10s %s\n' "opsmanager" "$OM_PORT" "$st" "HTTP $(http_code /user/login)"
}

current_url() { sed -n 's/^mms.centralUrl=//p' "$OM_PROPS" 2>/dev/null; }

update_central_url() { # update_central_url HOST -> 0 if changed, 1 if not
  local new="http://$1:$OM_PORT" cur; cur=$(current_url)
  [[ -n $cur ]] || die "No mms.centralUrl in $OM_PROPS. Is Ops Manager installed?"
  if [[ $cur == "$new" ]]; then info "mms.centralUrl=$cur"; return 1; fi
  sed -i "s#^mms.centralUrl=.*#mms.centralUrl=$new#" "$OM_PROPS"
  info "mms.centralUrl: $cur -> $new"
}

cmd_url() { load_state; current_url; }

cmd_set_url() {
  need_root set-url; load_state
  local host=${1:-$(default_host)}
  log "Setting mms.centralUrl"
  if update_central_url "$host" && systemctl is-active --quiet mongodb-mms; then
    info "Restarting Ops Manager to apply it"
    systemctl restart --no-block mongodb-mms
    wait_om
  fi
}

cmd_reset() {
  need_root reset
  warn "This DELETES the AppDB (data, users, configs, services) and uninstalls Ops Manager,"
  warn "including /etc/mongodb-mms/gen.key. It does not touch the sharded lab."
  if [[ ${FORCE:-0} != 1 ]]; then
    read -rp "    Type DELETE to continue: " ans
    [[ $ans == DELETE ]] || die "Cancelled."
  fi
  systemctl disable --now mongodb-mms >/dev/null 2>&1 || true
  if dpkg -s mongodb-mms >/dev/null 2>&1; then apt-get purge -y -qq mongodb-mms >/dev/null || true; fi
  rm -rf "${OM_HOME:?}" /etc/mongodb-mms /var/tmp/om-lab
  local m
  for m in "${MEMBERS[@]}"; do systemctl disable --now "appdb-lab@$m" >/dev/null 2>&1 || true; done
  rm -rf "${DATA_DIR:?}"
  rm -f "$LOG_DIR"/appdb-*.log*
  rm -rf "${CONF_DIR:?}"
  rm -f "$UNIT_DIR/appdb-lab@.service"
  systemctl daemon-reload
  [[ ${PURGE_BINARIES:-0} == 1 ]] && rm -rf "${BIN_ROOT:?}"
  log "Lab removed (AppDB binaries kept in $BIN_ROOT; PURGE_BINARIES=1 removes them). To build it again: sudo bash $0"
}

usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; }

detect_platform
[[ ${OMLAB_SOURCE_ONLY:-0} == 1 ]] && return 0 2>/dev/null
case ${1:-setup} in
  setup)  cmd_setup ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  reset)  cmd_reset ;;
  url)    cmd_url ;;
  set-url) cmd_set_url "${2:-}" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
