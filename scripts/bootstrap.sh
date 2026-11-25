#!/usr/bin/env bash
# Curl-friendly installer for a clean Linux machine.
#   curl -fsSL https://raw.githubusercontent.com/DeTTK/SCServer/main/scripts/bootstrap.sh | bash
# Environment: SCSERVER_DIR, SCSERVER_BRANCH, SCSERVER_REPO, SCSERVER_TARBALL_URL,
#              SCSERVER_NO_START=1, SCSERVER_PREPARE_ONLY=1
set -euo pipefail

REPO="${SCSERVER_REPO:-https://github.com/DeTTK/SCServer.git}"
BRANCH="${SCSERVER_BRANCH:-main}"
DIR="${SCSERVER_DIR:-$HOME/SCServer}"
REPO_URL="$REPO"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Bootstrap BSCPCRAFT / SCServer on Linux.

  curl -fsSL https://raw.githubusercontent.com/DeTTK/SCServer/main/scripts/bootstrap.sh | bash
  curl -fsSL .../bootstrap.sh | bash -s -- --start
  curl -fsSL .../bootstrap.sh | bash -s -- --output build/player-git-2 --start

Everything after "--" is passed to "scserver.sh install --from-scratch".
Environment:
  SCSERVER_DIR          checkout location (default ~/SCServer)
  SCSERVER_BRANCH       Git branch (default main)
  SCSERVER_REPO         Git URL or local clone (default upstream GitHub)
  SCSERVER_TARBALL_URL  source archive when git is unavailable
  SCSERVER_NO_START=1   do not start the server after installation
  SCSERVER_PREPARE_ONLY=1  only clone/update, skip install
EOF
}

for argument in "$@"; do
  case "$argument" in -h|--help) usage; exit 0 ;; esac
done

command -v bash >/dev/null 2>&1 || die "bash is required"
if ! command -v python3 >/dev/null 2>&1; then
  die "Python 3.10+ is required; install python3 (Debian/Ubuntu: sudo apt install python3 python3-venv)"
fi
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' || die "Python 3.10+ is required"
if ! command -v java >/dev/null 2>&1; then
  die "JDK 17+ is required; install it (Debian/Ubuntu: sudo apt install openjdk-17-jdk)"
fi
java_version="$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -1)"
[ "${java_version:-0}" = "1" ] && java_version=8
[ "${java_version:-0}" -ge 17 ] || die "JDK 17+ is required (found ${java_version:-unknown}); install openjdk-17-jdk"
command -v javac >/dev/null 2>&1 || die "javac is missing; install a JDK, not a JRE (openjdk-17-jdk)"

fetch_archive() {
  local url="$1" tmp="$2"
  command -v curl >/dev/null 2>&1 || die "curl is required when git is unavailable"
  command -v tar >/dev/null 2>&1 || die "tar is required when git is unavailable"
  say "downloading $url"
  curl -fsSL "$url" | tar -xz -C "$tmp" --strip-components=1
}

prepare_checkout() {
  if [ -d "$DIR/.git" ]; then
    say "updating $DIR ($BRANCH)"
    git -C "$DIR" fetch --quiet --depth 1 origin "$BRANCH"
    [ -z "$(git -C "$DIR" status --porcelain)" ] || die "the checkout has local changes: $DIR; commit or stash them first"
    git -C "$DIR" checkout --quiet "$BRANCH" 2>/dev/null || git -C "$DIR" checkout --quiet -B "$BRANCH" FETCH_HEAD
    git -C "$DIR" merge --ff-only FETCH_HEAD --quiet 2>/dev/null || die "cannot fast-forward $DIR; update it manually"
    return
  fi
  if [ -e "$DIR" ]; then
    die "$DIR exists but is not a Git checkout; remove it or set SCSERVER_DIR"
  fi
  mkdir -p "$(dirname "$DIR")"
  if command -v git >/dev/null 2>&1; then
    say "cloning $REPO_URL ($BRANCH) into $DIR"
    git clone --quiet --depth 1 --branch "$BRANCH" "$REPO_URL" "$DIR"
  else
    local tarball="${SCSERVER_TARBALL_URL:-}"
    if [ -z "$tarball" ]; then
      case "$REPO_URL" in
        https://github.com/*)
          local slug="${REPO_URL#https://github.com/}"
          tarball="https://codeload.github.com/${slug%.git}/tar.gz/refs/heads/$BRANCH"
          ;;
        *) die "git is not installed and SCSERVER_TARBALL_URL is not set" ;;
      esac
    fi
    local tmp
    tmp="$(mktemp -d)"
    fetch_archive "$tarball" "$tmp"
    mv "$tmp" "$DIR"
  fi
}

prepare_checkout
[ -f "$DIR/scripts/scserver.sh" ] || die "checkout at $DIR does not contain scripts/scserver.sh"
chmod +x "$DIR/scripts/scserver.sh" "$DIR/scripts/scserver_tui.py" 2>/dev/null || true

if [ "${SCSERVER_PREPARE_ONLY:-0}" = "1" ]; then
  say "checkout ready: $DIR"
  exit 0
fi

cd "$DIR"
args=("$@")
if [ "${SCSERVER_NO_START:-0}" != "1" ]; then
  case " ${args[*]} " in
    *" --start "*) ;;
    *) args+=(--start) ;;
  esac
fi
say "installing from $DIR"
exec ./scripts/scserver.sh install --from-scratch "${args[@]}"
