#!/usr/bin/env bash
# Linux install/run/control CLI for the source-built SCServer.
# Usage: scripts/scserver.sh {install|configure|build|start|stop|restart|status|health|logs|run|config|wipe|schedule|tui|uninstall}
set -euo pipefail

SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SCRIPT")/.." && pwd)"
CONF="$ROOT/.local/server.conf"
PATHS="$ROOT/.local/paths.json"
RUN_DIR="$ROOT/.local/run"
LOG_DIR="$ROOT/.local/logs"
PID_FILE="$RUN_DIR/server.pid"
PGID_FILE="$RUN_DIR/server.pgid"
SCHED_PID_FILE="$RUN_DIR/schedule.pid"
SCHED_NEXT_FILE="$RUN_DIR/wipe.next"
LOG_FILE="$LOG_DIR/server.log"
SCHED_LOG="$LOG_DIR/schedule.log"
BACKUP_DIR="$ROOT/.local/backups"
MAX_LOG_BYTES=52428800

SC_BUNDLE="${SC_BUNDLE:-}"
SC_MAP="${SC_MAP:-}"
SC_HOST="${SC_HOST:-}"
SC_PORT="${SC_PORT:-}"
SC_STATE="${SC_STATE:-}"
SC_WIPE_EVERY="${SC_WIPE_EVERY:-}"
SC_WIPE_KEEP="${SC_WIPE_KEEP:-5}"
SC_PYTHON="${SC_PYTHON:-python3}"
PYTHON="$SC_PYTHON"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
SCServer Linux CLI

  install [options]      check dependencies, import resources, build and link the CLI
  configure [options]    save bundle/map/host/port in .local/server.conf
  build                  build build/server.jar with pinned private resources
  start                  start the server in the background
  stop [--timeout N]     save and stop the server (default 90 s)
  restart                stop then start
  status                 show PID, uptime and admin health
  health                 query the admin /health endpoint
  logs [-f] [-n N]       show the server log (default 100 lines)
  run                    run in the foreground (Ctrl+C saves and stops)
  config                 print the resolved configuration
  wipe [--yes]           stop, back up and erase the world state, then restart
  schedule set --every SPEC [--keep N]   configure a periodic world wipe
  schedule start|stop|status             control the wipe daemon
  tui                    interactive dashboard (start/stop/wipe/logs/schedule)
  uninstall [--prefix D] remove the CLI link only (state and world are kept)

  SPEC is 30m, 6h or 1d (plain seconds are also accepted).
  A wipe archives the server state data folder to .local/backups and keeps
  the newest N copies; the read-only map is never touched.

Options for install/configure:
  --bundle DIR   compatible private Server folder (contains server.jar and fixtures)
  --map DIR      read-only map folder (contains region/ and registry.json)
  --host IP      bind/advertised address (default 127.0.0.1)
  --port N       base port (default 29544; gateway +1, world +2, admin +100, dev +104)
  --state DIR    persistent server state (default .local/server-state)
  --prefix DIR   CLI install location (default ~/.local/bin)

install only:
  --no-build         skip import/build, only link the CLI
  --force-import     re-import pinned resources even if already present
  --from-scratch     run scripts/build_player.py and use its Server/Map payload
  --output DIR       payload output for --from-scratch (default build/player-git)
  --start            start the server after installation
EOF
}

load_config() {
  if [ -f "$CONF" ]; then . "$CONF"; fi
  if { [ -z "$SC_BUNDLE" ] || [ -z "$SC_MAP" ]; } && [ -f "$PATHS" ]; then
    local line
    while IFS= read -r line; do eval "$line"; done < <("$PYTHON" - "$PATHS" <<'PY'
import json, shlex, sys
data = json.load(open(sys.argv[1], encoding="utf8"))
for key, var in (("server-bundle", "SC_BUNDLE"), ("map", "SC_MAP")):
    value = data.get(key)
    if value:
        print(f"export {var}={shlex.quote(str(value))}")
PY
)
  fi
  SC_HOST="${SC_HOST:-127.0.0.1}"
  SC_PORT="${SC_PORT:-29544}"
  SC_STATE="${SC_STATE:-$ROOT/.local/server-state}"
  SC_WIPE_EVERY="${SC_WIPE_EVERY:-}"
  SC_WIPE_KEEP="${SC_WIPE_KEEP:-5}"
  [ -n "$SC_MAP" ] && SC_MAP="$(normalize_map "$SC_MAP")"
  [ -n "$SC_BUNDLE" ] && SC_BUNDLE="$(realpath -m -- "$SC_BUNDLE")"
  [ -n "$SC_MAP" ] && SC_MAP="$(realpath -m -- "$SC_MAP")"
  [ -n "$SC_STATE" ] && SC_STATE="$(realpath -m -- "$SC_STATE")"
  PYTHON="$SC_PYTHON"
}

normalize_map() {
  local path="$1"
  if [ -d "$path/region" ]; then printf '%s' "$path"
  elif [ -d "$path/data/region" ]; then printf '%s' "$path/data"
  else printf '%s' "$path"; fi
}

validate_config() {
  [ -n "$SC_BUNDLE" ] || die "private Server bundle is not configured; run: $0 configure --bundle DIR --map DIR"
  [ -n "$SC_MAP" ] || die "map is not configured; run: $0 configure --bundle DIR --map DIR"
  [ -d "$SC_BUNDLE" ] || die "missing bundle directory: $SC_BUNDLE"
  [ -d "$SC_MAP" ] || die "missing map directory: $SC_MAP"
  [[ "$SC_PORT" =~ ^[0-9]+$ ]] && [ "$SC_PORT" -ge 1024 ] && [ "$SC_PORT" -le 65431 ] || die "port must be 1024..65431"
}

is_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid cmd
  pid="$(cat "$PID_FILE")"
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    case "$cmd" in *run_server.py*) return 0 ;; *) return 1 ;; esac
  fi
  return 0
}

admin_health() {
  local url="http://127.0.0.1:$((SC_PORT + 100))/health"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "$url" 2>/dev/null
  else
    "$PYTHON" - "$url" <<'PY' 2>/dev/null
import sys, urllib.request
print(urllib.request.urlopen(sys.argv[1], timeout=2).read().decode("utf8", "replace"), end="")
PY
  fi
}

java_major() {
  local version
  version="$("${JAVA_HOME:+$JAVA_HOME/bin/}java" -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -1)" || return 1
  [ -n "$version" ] || return 1
  [ "$version" = "1" ] && version=8
  printf '%s' "$version"
}

check_dependencies() {
  command -v "$PYTHON" >/dev/null 2>&1 || die "Python 3.10+ not found; install python3"
  "$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' || die "Python 3.10+ required"
  command -v java >/dev/null 2>&1 || die "JDK 17+ not found; install openjdk-17-jdk"
  local major
  major="$(java_major)" || die "cannot read the Java version"
  [ "$major" -ge 17 ] || die "JDK 17+ required (found $major)"
  command -v javac >/dev/null 2>&1 || say "warning: javac not found; build will fail, install a JDK rather than a JRE"
}

write_config() {
  mkdir -p "$(dirname "$CONF")"
  {
    printf '# Generated by scripts/scserver.sh; safe to edit.\n'
    printf 'SC_BUNDLE=%q\n' "$SC_BUNDLE"
    printf 'SC_MAP=%q\n' "$SC_MAP"
    printf 'SC_HOST=%q\n' "$SC_HOST"
    printf 'SC_PORT=%q\n' "$SC_PORT"
    printf 'SC_STATE=%q\n' "$SC_STATE"
    printf 'SC_WIPE_EVERY=%q\n' "$SC_WIPE_EVERY"
    printf 'SC_WIPE_KEEP=%q\n' "$SC_WIPE_KEEP"
    [ -n "${JAVA_HOME:-}" ] && printf 'JAVA_HOME=%q\n' "$JAVA_HOME"
  } > "$CONF"
  say "saved $CONF"
}

parse_common() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --bundle) [ $# -ge 2 ] || die "$1 needs a value"; SC_BUNDLE="$2"; shift 2 ;;
      --map) [ $# -ge 2 ] || die "$1 needs a value"; SC_MAP="$(normalize_map "$2")"; shift 2 ;;
      --host) [ $# -ge 2 ] || die "$1 needs a value"; SC_HOST="$2"; shift 2 ;;
      --port) [ $# -ge 2 ] || die "$1 needs a value"; SC_PORT="$2"; shift 2 ;;
      --state) [ $# -ge 2 ] || die "$1 needs a value"; SC_STATE="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

cmd_configure() {
  load_config
  parse_common "$@"
  [ -d "$SC_BUNDLE" ] || die "missing bundle directory: $SC_BUNDLE"
  [ -d "$SC_MAP" ] || die "missing map directory: $SC_MAP"
  validate_config
  write_config
}

import_resources() {
  local flag="${1:-}"
  if [ "$flag" != "--force-import" ] && [ -f "$ROOT/.local/server-resources/assets/bundle/feature_flags.json" ]; then
    say "private resources already imported"
    return 0
  fi
  [ -f "$SC_BUNDLE/server.jar" ] || die "missing $SC_BUNDLE/server.jar for resource import"
  "$PYTHON" "$ROOT/scripts/import_private_resources.py" --server-jar "$SC_BUNDLE/server.jar"
}

cmd_build() {
  load_config
  validate_config
  check_dependencies
  import_resources
  "$PYTHON" "$ROOT/scripts/build.py" server --private-resources
  say "built $ROOT/build/server.jar"
}

rotate_log() {
  mkdir -p "$LOG_DIR" "$RUN_DIR"
  if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi
}

cmd_start() {
  load_config
  validate_config
  mkdir -p "$RUN_DIR" "$LOG_DIR"
  if is_running; then die "already running (pid $(cat "$PID_FILE"))"; fi
  rm -f "$PID_FILE" "$PGID_FILE"
  [ -f "$ROOT/build/server.jar" ] || die "build/server.jar not found; run: $0 build"
  rotate_log
  say "starting on $SC_HOST:$SC_PORT (state $SC_STATE)"
  # setsid may fork; the wrapper records the real session leader PID itself.
  setsid bash -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' _ "$PID_FILE" \
    "$PYTHON" "$ROOT/scripts/run_server.py" \
    --bundle "$SC_BUNDLE" --map "$SC_MAP" --state "$SC_STATE" \
    --host "$SC_HOST" --port "$SC_PORT" >>"$LOG_FILE" 2>&1 &
  local pid="" waited=0
  while [ "$waited" -lt 50 ]; do
    [ -s "$PID_FILE" ] && { pid="$(cat "$PID_FILE")"; break; }
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ -z "$pid" ]; then
    rm -f "$PID_FILE" "$PGID_FILE"
    die "server failed to start; see: $0 logs"
  fi
  printf '%s\n' "$pid" > "$PGID_FILE"
  sleep 0.5
  if ! is_running; then
    rm -f "$PID_FILE" "$PGID_FILE"
    die "server exited during startup; see: $0 logs"
  fi
  say "running pid $pid; log: $LOG_FILE"
  say "stop with: $0 stop"
}

wait_stopped() {
  local pid="$1" limit="$2" waited=0 state
  while kill -0 "$pid" 2>/dev/null; do
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')" || state=""
    [ "${state#Z}" != "$state" ] && return 0
    [ "$waited" -ge "$limit" ] && return 1
    sleep 0.5
    waited=$((waited + 1))
  done
  return 0
}

cmd_stop() {
  load_config
  local timeout=90
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) [ $# -ge 2 ] || die "$1 needs a value"; timeout="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  if ! is_running; then
    rm -f "$PID_FILE" "$PGID_FILE"
    say "not running"
    return 0
  fi
  local pid pgid
  pid="$(cat "$PID_FILE")"
  pgid="$(cat "$PGID_FILE" 2>/dev/null || cat "$PID_FILE")"
  [[ "$pgid" =~ ^[0-9]+$ ]] && [ "$pgid" -gt 1 ] || pgid="$pid"
  say "saving and stopping pid $pid (up to ${timeout}s)"
  kill -INT -- "-$pgid" 2>/dev/null || kill -INT "$pid" 2>/dev/null || true
  if ! wait_stopped "$pid" $((timeout * 2)); then
    say "graceful shutdown timed out; sending SIGTERM"
    kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    if ! wait_stopped "$pid" 20; then
      say "still alive; sending SIGKILL"
      kill -KILL -- "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      wait_stopped "$pid" 10 || true
    fi
  fi
  rm -f "$PID_FILE" "$PGID_FILE"
  say "stopped"
}

cmd_restart() { cmd_stop "$@"; cmd_start; }

cmd_status() {
  load_config
  if ! is_running; then
    if [ -f "$PID_FILE" ]; then
      rm -f "$PID_FILE" "$PGID_FILE"
      say "stopped (removed stale pid file)"
    else
      say "stopped"
    fi
    return 1
  fi
  local pid uptime health
  pid="$(cat "$PID_FILE")"
  uptime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
  say "running pid $pid, uptime ${uptime:-?}"
  say "address $SC_HOST:$SC_PORT; state $SC_STATE"
  if health="$(admin_health)"; then say "health $health"; else say "health unreachable (127.0.0.1:$((SC_PORT + 100))/health)"; fi
  say "log $LOG_FILE"
}

cmd_health() {
  load_config
  is_running || die "server is not running"
  admin_health || die "admin health endpoint is unreachable"
}

cmd_logs() {
  load_config
  local lines=100 follow=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow) follow=1; shift ;;
      -n) [ $# -ge 2 ] || die "$1 needs a value"; lines="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -f "$LOG_FILE" ] || die "no log yet: $LOG_FILE"
  if [ "$follow" -eq 1 ]; then exec tail -n "$lines" -f "$LOG_FILE"
  else tail -n "$lines" "$LOG_FILE"; fi
}

cmd_run() {
  load_config
  validate_config
  mkdir -p "$RUN_DIR" "$LOG_DIR"
  if is_running; then die "already running (pid $(cat "$PID_FILE"))"; fi
  [ -f "$ROOT/build/server.jar" ] || die "build/server.jar not found; run: $0 build"
  say "foreground server on $SC_HOST:$SC_PORT; Ctrl+C saves and stops"
  exec "$PYTHON" "$ROOT/scripts/run_server.py" \
    --bundle "$SC_BUNDLE" --map "$SC_MAP" --state "$SC_STATE" \
    --host "$SC_HOST" --port "$SC_PORT"
}

cmd_config() {
  load_config
  printf 'bundle=%s\nmap=%s\nhost=%s\nport=%s\nstate=%s\npython=%s\njava=%s\nwipeEvery=%s\nwipeKeep=%s\n' \
    "${SC_BUNDLE:-}" "${SC_MAP:-}" "$SC_HOST" "$SC_PORT" "$SC_STATE" "$PYTHON" \
    "${JAVA_HOME:-$(command -v java 2>/dev/null || true)}" "$SC_WIPE_EVERY" "$SC_WIPE_KEEP"
}

parse_interval() {
  local spec="$1" number unit
  [[ "$spec" =~ ^([0-9]+)([smhd]?)$ ]] || return 1
  number="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  [ "$number" -gt 0 ] || return 1
  case "$unit" in
    ""|s) printf '%s' "$number" ;;
    m) printf '%s' $((number * 60)) ;;
    h) printf '%s' $((number * 3600)) ;;
    d) printf '%s' $((number * 86400)) ;;
  esac
}

sched_running() {
  [ -f "$SCHED_PID_FILE" ] || return 1
  local pid cmd
  pid="$(cat "$SCHED_PID_FILE")"
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    case "$cmd" in *__schedule_loop*) return 0 ;; *) return 1 ;; esac
  fi
  return 0
}

backup_world() {
  local keep="$1" stamp path base counter=1
  [ -d "$SC_STATE/data" ] || return 0
  command -v tar >/dev/null 2>&1 || { say "error: tar is required for world backups"; return 1; }
  mkdir -p "$BACKUP_DIR"
  stamp="$(date +%Y%m%d-%H%M%S)"
  base="$BACKUP_DIR/world-$stamp"
  path="$base.tar.gz"
  while [ -e "$path" ]; do path="$base-$counter.tar.gz"; counter=$((counter + 1)); done
  say "backing up world to $path"
  tar -czf "$path" -C "$SC_STATE" data || { say "error: backup failed"; return 1; }
  while IFS= read -r path; do rm -f -- "$path"; done < <(ls -1t "$BACKUP_DIR"/world-*.tar.gz 2>/dev/null | tail -n +$((keep + 1)))
  return 0
}

wipe_world() {
  local keep="$1" no_backup="$2" was_running=0
  if is_running; then was_running=1; fi
  if [ "$was_running" -eq 1 ]; then
    say "stopping the server for a wipe"
    ( cmd_stop --timeout 120 ) || { say "error: server did not stop"; return 1; }
  fi
  if [ -d "$SC_STATE/data" ]; then
    if [ "$no_backup" != "1" ]; then backup_world "$keep" || return 1; fi
    say "erasing $SC_STATE/data"
    rm -rf -- "$SC_STATE/data" || { say "error: cannot erase world data"; return 1; }
  else
    say "world data is already empty: $SC_STATE/data"
  fi
  if [ "$was_running" -eq 1 ]; then
    say "restarting the server on the fresh world"
    ( cmd_start ) || { say "error: server restart failed; check: $0 logs"; return 1; }
  fi
  return 0
}

perform_wipe() {
  local keep="$1" no_backup="$2" status
  command -v flock >/dev/null 2>&1 || { say "error: flock from util-linux is required"; return 1; }
  mkdir -p "$RUN_DIR"
  exec 9>"$RUN_DIR/wipe.lock"
  if ! flock -n 9; then
    exec 9>&-
    say "error: another wipe is already running"
    return 1
  fi
  wipe_world "$keep" "$no_backup"
  status=$?
  flock -u 9 2>/dev/null || true
  exec 9>&-
  return "$status"
}

cmd_wipe() {
  load_config
  local keep="$SC_WIPE_KEEP" yes=0 no_backup=0 reply
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      --no-backup) no_backup=1; shift ;;
      --keep) [ $# -ge 2 ] || die "$1 needs a value"; keep="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ "$keep" =~ ^[1-9][0-9]*$ ]] || die "--keep must be a positive integer"
  if [ "$yes" -eq 0 ]; then
    [ -t 0 ] || die "refusing a non-interactive wipe without --yes"
    printf 'Erase world state %s? A backup will be written to %s. [y/N] ' "$SC_STATE/data" "$BACKUP_DIR"
    read -r reply || reply=""
    case "$reply" in y|Y|yes|YES) ;; *) say "cancelled"; return 0 ;; esac
  fi
  perform_wipe "$keep" "$no_backup" || return 1
  say "wipe complete (kept $keep newest backups)"
}

cmd_schedule_loop() {
  load_config
  mkdir -p "$RUN_DIR" "$LOG_DIR"
  local seconds next stop=0 sleeper
  seconds="$(parse_interval "$SC_WIPE_EVERY")" || die "invalid wipe interval: $SC_WIPE_EVERY"
  trap 'stop=1' TERM INT
  say "scheduler started $(date "+%Y-%m-%d %H:%M:%S"): every $SC_WIPE_EVERY, keep $SC_WIPE_KEEP backups"
  while [ "$stop" -eq 0 ]; do
    next=$(( $(date +%s) + seconds ))
    printf '%s\n' "$next" > "$SCHED_NEXT_FILE"
    say "next wipe at $(date -d "@$next" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$next")"
    sleep "$seconds" &
    sleeper=$!
    wait "$sleeper" 2>/dev/null || true
    [ "$stop" -eq 1 ] && break
    say "scheduled wipe started $(date "+%Y-%m-%d %H:%M:%S")"
    if ! perform_wipe "$SC_WIPE_KEEP" ""; then
      say "wipe failed; the next attempt is in $SC_WIPE_EVERY"
    fi
  done
  rm -f "$SCHED_NEXT_FILE"
  say "scheduler stopped $(date "+%Y-%m-%d %H:%M:%S")"
}

cmd_schedule() {
  local action="${1:-status}"
  [ $# -gt 0 ] && shift
  load_config
  case "$action" in
    set)
      local every="" keep="$SC_WIPE_KEEP"
      while [ $# -gt 0 ]; do
        case "$1" in
          --every) [ $# -ge 2 ] || die "$1 needs a value"; every="$2"; shift 2 ;;
          --keep) [ $# -ge 2 ] || die "$1 needs a value"; keep="$2"; shift 2 ;;
          *) die "unknown option: $1" ;;
        esac
      done
      [ -n "$every" ] || die "usage: $0 schedule set --every SPEC [--keep N]"
      parse_interval "$every" >/dev/null || die "invalid interval (use 30m, 6h, 1d or seconds)"
      [[ "$keep" =~ ^[1-9][0-9]*$ ]] || die "--keep must be a positive integer"
      local restart=0
      if sched_running; then restart=1; fi
      SC_WIPE_EVERY="$every"; SC_WIPE_KEEP="$keep"
      write_config
      say "wipe schedule saved: every $every, keep $keep backups"
      if [ "$restart" -eq 1 ]; then
        say "restarting the scheduler to apply the new interval"
        cmd_schedule stop
        cmd_schedule start
      fi
      ;;
    start)
      validate_config
      [ -n "$SC_WIPE_EVERY" ] || die "no interval configured; run: $0 schedule set --every 6h"
      parse_interval "$SC_WIPE_EVERY" >/dev/null || die "invalid configured interval: $SC_WIPE_EVERY"
      mkdir -p "$RUN_DIR" "$LOG_DIR"
      if sched_running; then
        say "scheduler already running (pid $(cat "$SCHED_PID_FILE")); restarting"
        cmd_schedule stop
      fi
      rm -f "$SCHED_PID_FILE" "$SCHED_NEXT_FILE"
      setsid bash -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' _ "$SCHED_PID_FILE" \
        "$SCRIPT" __schedule_loop >>"$SCHED_LOG" 2>&1 &
      local waited=0 pid=""
      while [ "$waited" -lt 50 ]; do
        [ -s "$SCHED_PID_FILE" ] && { pid="$(cat "$SCHED_PID_FILE")"; break; }
        sleep 0.1
        waited=$((waited + 1))
      done
      [ -n "$pid" ] || die "scheduler failed to start; see $SCHED_LOG"
      say "scheduler running pid $pid; log $SCHED_LOG"
      ;;
    stop)
      if sched_running; then
        local pid
        pid="$(cat "$SCHED_PID_FILE")"
        kill -TERM "$pid" 2>/dev/null || true
        wait_stopped "$pid" 20 || kill -KILL "$pid" 2>/dev/null || true
        say "scheduler stopped"
      else
        say "scheduler is not running"
      fi
      rm -f "$SCHED_PID_FILE" "$SCHED_NEXT_FILE"
      ;;
    status)
      if sched_running; then
        say "scheduler running pid $(cat "$SCHED_PID_FILE")"
      else
        say "scheduler stopped"
      fi
      say "interval: ${SC_WIPE_EVERY:-not configured}; keep $SC_WIPE_KEEP backups"
      if sched_running && [ -s "$SCHED_NEXT_FILE" ]; then
        local next remaining
        next="$(cat "$SCHED_NEXT_FILE")"
        remaining=$((next - $(date +%s)))
        [ "$remaining" -lt 0 ] && remaining=0
        say "next wipe: $(date -d "@$next" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$next") (in ${remaining}s)"
      fi
      ;;
    *) die "usage: $0 schedule {set --every SPEC [--keep N]|start|stop|status}" ;;
  esac
}

cmd_install() {
  local prefix="$HOME/.local/bin" no_build=0 force_import="" from_scratch=0 start_after=0
  local output="$ROOT/build/player-git" common=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) [ $# -ge 2 ] || die "$1 needs a value"; prefix="$2"; shift 2 ;;
      --output) [ $# -ge 2 ] || die "$1 needs a value"; output="$2"; shift 2 ;;
      --no-build) no_build=1; shift ;;
      --force-import) force_import="--force-import"; shift ;;
      --from-scratch) from_scratch=1; shift ;;
      --start) start_after=1; shift ;;
      --bundle|--map|--host|--port|--state) common+=("$1" "$2"); [ $# -ge 2 ] || die "$1 needs a value"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  check_dependencies
  load_config
  parse_common "${common[@]}"
  if [ "$from_scratch" -eq 1 ]; then
    output="$(realpath -m -- "$output")"
    case "$output" in "$ROOT"/build/*) ;; *) die "--output for --from-scratch must be inside $ROOT/build" ;; esac
    local bundle="$output/player/Server" map="$output/player/Map"
    if [ -f "$bundle/server.jar" ]; then
      say "reusing complete payload: $output; rebuilding build/server.jar"
      no_build=0
    else
      [ -e "$output" ] && die "output directory already exists and is incomplete: $output; choose another --output"
      say "building the complete game payload from this checkout; this takes a while"
      "$PYTHON" "$ROOT/scripts/build_player.py" --output "$output"
    fi
    [ -f "$bundle/server.jar" ] || die "build_player.py did not produce $bundle/server.jar"
    SC_BUNDLE="$bundle"; SC_MAP="$map"; no_build=1
  fi
  validate_config
  write_config
  mkdir -p "$SC_STATE" "$RUN_DIR" "$LOG_DIR"
  if [ "$no_build" -eq 0 ]; then
    import_resources "$force_import"
    "$PYTHON" "$ROOT/scripts/build.py" server --private-resources
  fi
  mkdir -p "$prefix"
  ln -sfn "$SCRIPT" "$prefix/scserver"
  say "linked $prefix/scserver"
  case ":$PATH:" in
    *":$prefix:"*) ;;
    *) say "add to PATH: export PATH=\"$prefix:\$PATH\"" ;;
  esac
  if [ "$start_after" -eq 1 ]; then
    cmd_start
  else
    say "installed; start with: scserver start"
  fi
}

cmd_tui() {
  load_config
  [ -t 0 ] && [ -t 1 ] || die "tui requires an interactive terminal"
  exec "$PYTHON" "$ROOT/scripts/scserver_tui.py"
}

cmd_uninstall() {
  local prefix="$HOME/.local/bin"
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) [ $# -ge 2 ] || die "$1 needs a value"; prefix="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  if is_running; then die "stop the server first: $0 stop"; fi
  rm -f "$prefix/scserver"
  say "removed $prefix/scserver; .local state and worlds were kept"
}

command="${1:-help}"
[ $# -gt 0 ] && shift
case "$command" in
  install) cmd_install "$@" ;;
  configure) cmd_configure "$@" ;;
  build) cmd_build "$@" ;;
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  restart) cmd_restart "$@" ;;
  status) cmd_status "$@" ;;
  health) cmd_health "$@" ;;
  logs) cmd_logs "$@" ;;
  run) cmd_run "$@" ;;
  config) cmd_config "$@" ;;
  wipe) cmd_wipe "$@" ;;
  schedule) cmd_schedule "$@" ;;
  tui) cmd_tui "$@" ;;
  __schedule_loop) cmd_schedule_loop "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  help|-h|--help) usage ;;
  *) usage; die "unknown command: $command" ;;
esac
