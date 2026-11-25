#!/usr/bin/env python3
"""Curses dashboard for scripts/scserver.sh: status, log, start/stop, wipes and schedule."""
from pathlib import Path
import curses, os, shlex, subprocess, sys, time, urllib.request

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "scserver.sh"
CONF = ROOT / ".local" / "server.conf"
RUN = ROOT / ".local" / "run"
PID = RUN / "server.pid"
SCHED_PID = RUN / "schedule.pid"
NEXT = RUN / "wipe.next"
LOG = ROOT / ".local" / "logs" / "server.log"
DEFAULT_STATE = ROOT / ".local" / "server-state"


def load_conf():
    data = {"SC_HOST": "127.0.0.1", "SC_PORT": "29544", "SC_STATE": str(DEFAULT_STATE),
            "SC_WIPE_EVERY": "", "SC_WIPE_KEEP": "5"}
    try:
        for line in CONF.read_text(encoding="utf8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, raw = line.split("=", 1)
            try:
                parts = shlex.split(raw)
            except ValueError:
                parts = [raw]
            data[key] = " ".join(parts)
    except OSError:
        pass
    return data


def cmdline(pid):
    try:
        return Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode("utf8", "replace")
    except OSError:
        return ""


def read_pid(path, marker):
    try:
        pid = int(path.read_text().strip())
    except (OSError, ValueError):
        return 0
    return pid if marker in cmdline(pid) else 0


def server_pid():
    return read_pid(PID, "run_server.py")


def scheduler_pid():
    return read_pid(SCHED_PID, "__schedule_loop")


def next_wipe():
    try:
        return int(NEXT.read_text().strip())
    except (OSError, ValueError):
        return 0


def uptime(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        started = int(fields[19]) / os.sysconf("SC_CLK_TCK")
        btime = next(int(line.split()[1]) for line in Path("/proc/stat").read_text().splitlines() if line.startswith("btime "))
        return max(0, int(time.time() - btime - started))
    except (OSError, ValueError, IndexError, StopIteration):
        return 0


def hms(seconds):
    seconds = max(0, int(seconds))
    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)
    if days:
        return f"{days}d {hours:02d}:{minutes:02d}:{seconds:02d}"
    if hours:
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}"
    return f"{minutes:02d}:{seconds:02d}"


def tail(path, count):
    try:
        with path.open("rb") as source:
            source.seek(0, 2)
            size = source.tell()
            source.seek(max(0, size - 131072))
            rows = source.read().decode("utf8", "replace").splitlines()
        return rows[-count:]
    except OSError:
        return []


def health(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port + 100}/health", timeout=0.3) as response:
            return response.read(160).decode("utf8", "replace").strip() or "ok"
    except Exception:
        return "unreachable"


def suspend(screen):
    curses.def_prog_mode()
    curses.endwin()


def resume(screen):
    curses.reset_prog_mode()
    screen.refresh()


def run_action(screen, args, message):
    suspend(screen)
    print(f"$ {SCRIPT.name} {' '.join(args)}\n", flush=True)
    try:
        code = subprocess.call([str(SCRIPT), *args])
    except KeyboardInterrupt:
        code = 130
    print(f"\n[exit {code}]")
    try:
        input("Press Enter to return to the dashboard...")
    except EOFError:
        pass
    resume(screen)
    return f"{' '.join(args)}: exit {code}", code


def put(screen, row, column, text, attr=0, width=None):
    height, cols = screen.getmaxyx()
    if row < 0 or row >= height or column >= cols:
        return
    limit = (width if width is not None else cols - column - 1)
    try:
        screen.addnstr(row, column, str(text).replace("\t", "    "), max(0, limit), attr)
    except curses.error:
        pass


def draw(screen, message, scroll):
    height, cols = screen.getmaxyx()
    screen.erase()
    conf = load_conf()
    try:
        port = int(conf.get("SC_PORT", "29544"))
    except ValueError:
        port = 29544
    pid = server_pid()
    sched = scheduler_pid()
    stamp = time.strftime("%H:%M:%S")
    green = curses.color_pair(1) if curses.has_colors() else 0
    red = curses.color_pair(2) if curses.has_colors() else 0
    yellow = curses.color_pair(3) if curses.has_colors() else 0
    cyan = curses.color_pair(4) if curses.has_colors() else 0

    put(screen, 0, 0, "BSCPCRAFT / SCServer control", curses.A_BOLD)
    put(screen, 0, max(0, cols - len(stamp) - 1), stamp)
    if pid:
        put(screen, 1, 0, f"RUNNING  pid {pid}  up {hms(uptime(pid))}", green | curses.A_BOLD)
    else:
        put(screen, 1, 0, "STOPPED", red | curses.A_BOLD)
    configured = bool(conf.get("SC_BUNDLE") or CONF.exists())
    if not configured:
        put(screen, 1, 12, "not configured: run ./scripts/scserver.sh install", yellow)
    put(screen, 2, 0, f"address {conf.get('SC_HOST', '127.0.0.1')}:{port}   state {conf.get('SC_STATE', DEFAULT_STATE)}")
    put(screen, 3, 0, f"admin health: {health(port) if pid else '-'}")

    every = conf.get("SC_WIPE_EVERY", "")
    keep = conf.get("SC_WIPE_KEEP", "5")
    if every:
        state = f"daemon pid {sched}" if sched else "daemon stopped"
        next_at = next_wipe() if sched else 0
        if next_at:
            remaining = hms(next_at - time.time())
            when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(next_at))
            schedule = f"schedule: every {every}, keep {keep}   {state}   next {when} (in {remaining})"
        else:
            schedule = f"schedule: every {every}, keep {keep}   {state}"
    else:
        schedule = "schedule: off (press e to set an interval)"
    put(screen, 4, 0, schedule, cyan)
    put(screen, 5, 0, "-" * max(0, cols - 1))

    log_top, log_bottom = 6, height - 3
    if log_bottom > log_top:
        count = log_bottom - log_top
        rows = tail(LOG, count + scroll + 1)
        if scroll:
            rows = rows[:-scroll] if scroll < len(rows) else []
        rows = rows[-count:]
        for index, line in enumerate(rows):
            put(screen, log_top + index, 0, line, width=cols - 1)

    keys = "[s]tart [x]stop [r]restart [w]ipe [e]very [a]schedule on [d]off [j/k]scroll [q]uit"
    put(screen, height - 2, 0, keys, curses.A_DIM, width=cols - 1)
    put(screen, height - 1, 0, message or ("log: " + str(LOG)), curses.A_REVERSE, width=cols - 1)
    screen.refresh()


def prompt(screen, label):
    height, _ = screen.getmaxyx()
    curses.echo()
    curses.curs_set(1)
    try:
        screen.move(height - 1, 0)
        screen.clrtoeol()
        screen.addstr(height - 1, 0, label)
        screen.refresh()
        return screen.getstr(height - 1, len(label), 24).decode("utf8", "replace").strip()
    except (KeyboardInterrupt, curses.error):
        return ""
    finally:
        curses.noecho()
        curses.curs_set(0)


def main(screen):
    curses.curs_set(0)
    screen.timeout(500)
    if curses.has_colors():
        curses.start_color()
        try:
            curses.use_default_colors()
        except curses.error:
            pass
        curses.init_pair(1, curses.COLOR_GREEN, -1)
        curses.init_pair(2, curses.COLOR_RED, -1)
        curses.init_pair(3, curses.COLOR_YELLOW, -1)
        curses.init_pair(4, curses.COLOR_CYAN, -1)
    message, scroll = "", 0
    while True:
        draw(screen, message, scroll)
        key = screen.getch()
        if key == -1:
            continue
        if key in (ord("q"), 27):
            break
        if key in (curses.KEY_RESIZE,):
            scroll = 0
            continue
        if key in (curses.KEY_DOWN, ord("j")):
            scroll = max(0, scroll - 1)
            continue
        if key in (curses.KEY_UP, ord("k")):
            scroll = min(500, scroll + 1)
            continue
        if key == ord("s"):
            message, _ = run_action(screen, ["start"], message)
        elif key == ord("x"):
            message, _ = run_action(screen, ["stop"], message)
        elif key == ord("r"):
            message, _ = run_action(screen, ["restart"], message)
        elif key == ord("w"):
            message, _ = run_action(screen, ["wipe"], message)
        elif key == ord("a"):
            message, _ = run_action(screen, ["schedule", "start"], message)
        elif key == ord("d"):
            message, _ = run_action(screen, ["schedule", "stop"], message)
        elif key == ord("e"):
            value = prompt(screen, "wipe interval (30m, 6h, 1d): ")
            if value:
                message, _ = run_action(screen, ["schedule", "set", "--every", value], message)
            else:
                message = "interval unchanged"


if __name__ == "__main__":
    if not sys.stdout.isatty() or not sys.stdin.isatty():
        raise SystemExit("tui requires an interactive terminal")
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
