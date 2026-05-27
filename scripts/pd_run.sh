#!/usr/bin/env bash
# Iteration harness for PureDarwin in QEMU.
#
# Subcommands:
#   probe [duration] [pattern]   boot, wait until match/panic/timeout, exit
#   start                        boot async; return when QEMU + relay are up
#   boot                         boot and stream serial to stdout
#   wait [pattern] [t]           wait until serial matches; default = launchd-up
#   shot [path]                  screendump current QEMU display to PNG
#   sendkey <keys...>            forward sendkey commands to QEMU monitor
#   send <text>                  type <text>+Enter into the guest console
#   sendraw <text>               write <text> to guest console without Enter
#   interact                     attach stdin/stdout to guest console (Ctrl-]Q to quit)
#   kill                         stop any running QEMU and clean up
#
# Globals exposed:
#   /tmp/pd_serial.log     live serial console capture (append-only)
#   /tmp/pd_qemu.pid       QEMU pid file
#   /tmp/pd_mon.sock       QEMU monitor socket (text protocol)
#   /tmp/pd_console.sock   QEMU serial chardev (bidirectional)
#   /tmp/pd_console_in     FIFO; bytes written here go into guest stdin
#   /tmp/pd_relay.pid      pd_console_relay.py pid file
#   /tmp/pd_screen.png     most recent screendump
#
# Exit codes from probe:
#   0  pattern matched
#   1  timeout
#   2  panic detected
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$HOME/PureDarwin/userland/boot"
RAW="$PROJ_DIR/pd_17_4_modded.raw"
VMDK="$PROJ_DIR/pd_17_4_modded.vmdk"
SERIAL_LOG="/tmp/pd_serial.log"
MONITOR_SOCK="/tmp/pd_mon.sock"
CONSOLE_SOCK="/tmp/pd_console.sock"
CONSOLE_IN="/tmp/pd_console_in"
RELAY_PID_FILE="/tmp/pd_relay.pid"
SCREENSHOT_PPM="/tmp/pd_screen.ppm"
SCREENSHOT_PNG="/tmp/pd_screen.png"
PID_FILE="/tmp/pd_qemu.pid"
RELAY_PY="$SCRIPT_DIR/pd_console_relay.py"

QEMU=qemu-system-x86_64
QEMU_ARGS=(
  -m 2G
  -cpu Penryn
  -drive "file=$VMDK,format=vmdk,if=ide"
  -netdev user,id=net0,hostfwd=tcp::2222-:22
  -device rtl8139,netdev=net0
  -display none
  -chardev "socket,id=s0,path=$CONSOLE_SOCK,server=on,wait=off"
  -serial chardev:s0
  -monitor "unix:$MONITOR_SOCK,server,nowait"
  -no-reboot
)

mon() {
  printf "%s\n" "$*" | nc -U "$MONITOR_SOCK" -w 1 2>/dev/null || true
}

shot() {
  local out="${1:-$SCREENSHOT_PNG}"
  rm -f "$SCREENSHOT_PPM"
  mon "screendump $SCREENSHOT_PPM" >/dev/null
  for _ in $(seq 1 30); do
    [ -s "$SCREENSHOT_PPM" ] && break
    sleep 0.2
  done
  if [ ! -s "$SCREENSHOT_PPM" ]; then
    echo "shot: no screendump produced" >&2; return 1
  fi
  sips -s format png "$SCREENSHOT_PPM" --out "$out" >/dev/null
  echo "$out"
}

kill_qemu() {
  if [ -f "$RELAY_PID_FILE" ]; then
    local rpid; rpid=$(cat "$RELAY_PID_FILE" 2>/dev/null || true)
    [ -n "$rpid" ] && kill "$rpid" 2>/dev/null || true
    rm -f "$RELAY_PID_FILE"
  fi
  if [ -f "$PID_FILE" ]; then
    local pid; pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      mon "quit" >/dev/null 2>&1 || true
      sleep 0.3
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
  pkill -9 -f "$QEMU.*pd_17_4_modded" 2>/dev/null || true
  pkill -9 -f "pd_console_relay.py" 2>/dev/null || true
  rm -f "$MONITOR_SOCK" "$CONSOLE_SOCK" "$CONSOLE_IN"
}

ensure_vmdk() {
  if [ ! -f "$VMDK" ] || [ "$RAW" -nt "$VMDK" ]; then
    echo "Rebuilding VMDK from raw..."
    rm -f "$VMDK"
    qemu-img convert -f raw "$RAW" -O vmdk "$VMDK"
  fi
}

boot_async() {
  ensure_vmdk
  : > "$SERIAL_LOG"
  rm -f "$MONITOR_SOCK" "$CONSOLE_SOCK" "$CONSOLE_IN" "$PID_FILE" "$RELAY_PID_FILE"
  "$QEMU" "${QEMU_ARGS[@]}" >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"

  for _ in $(seq 1 50); do
    [ -S "$MONITOR_SOCK" ] && break
    sleep 0.1
  done

  # Start console relay (socket <-> serial.log + FIFO).
  PD_CONSOLE_SOCK="$CONSOLE_SOCK" PD_SERIAL_LOG="$SERIAL_LOG" \
  PD_CONSOLE_IN="$CONSOLE_IN" PD_RELAY_PID="$RELAY_PID_FILE" \
    python3 "$RELAY_PY" >/dev/null 2>&1 &

  # Chameleon shows a "boot:" prompt and waits forever w/o a Timeout key.
  # Send Enter twice (a few seconds apart) to start the default boot.
  ( sleep 4; mon "sendkey ret" >/dev/null;
    sleep 4; mon "sendkey ret" >/dev/null ) &
  echo "$pid"
}

# Ensure FIFO exists for `send` even when no QEMU is running.
ensure_fifo() {
  if [ ! -p "$CONSOLE_IN" ]; then
    echo "console FIFO $CONSOLE_IN not present (is QEMU running?)" >&2
    return 1
  fi
}

wait_for() {
  local pattern="${1:-com.apple.launchd}"
  local timeout="${2:-300}"
  local start=$SECONDS
  while :; do
    if grep -q -- "$pattern" "$SERIAL_LOG" 2>/dev/null; then
      echo "matched: $pattern (t=$((SECONDS-start))s, $(stat -f '%z' "$SERIAL_LOG") bytes)"
      return 0
    fi
    if grep -q -E "panic|Kernel trap|Debugger called" "$SERIAL_LOG" 2>/dev/null; then
      echo "PANIC detected (t=$((SECONDS-start))s)"
      grep -nE "panic|Kernel trap|Debugger called" "$SERIAL_LOG" | head -5
      return 2
    fi
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      echo "timeout after ${timeout}s (serial size $(stat -f '%z' "$SERIAL_LOG"))"
      return 1
    fi
    sleep 1
  done
}

case "${1:-probe}" in
  kill) kill_qemu ;;
  shot) shot "${2:-$SCREENSHOT_PNG}" ;;
  sendkey)
    shift
    mon "sendkey $*"
    ;;
  send)
    shift
    ensure_fifo
    # Append CR (Enter) so the guest shell sees a complete line.
    printf '%s\r' "$*" > "$CONSOLE_IN"
    ;;
  sendraw)
    shift
    ensure_fifo
    printf '%s' "$*" > "$CONSOLE_IN"
    ;;
  interact)
    ensure_fifo
    echo "--- pd_run interact: type to send. Ctrl-D to detach. ---" >&2
    # tail -F runs forever; stdin lines go to the FIFO.
    ( tail -n 50 -F "$SERIAL_LOG" & echo $! > /tmp/pd_tail.pid; wait ) &
    tail_pid=$!
    trap '[ -f /tmp/pd_tail.pid ] && kill -9 $(cat /tmp/pd_tail.pid) 2>/dev/null; rm -f /tmp/pd_tail.pid; kill $tail_pid 2>/dev/null' EXIT INT TERM
    while IFS= read -r line; do
      printf '%s\r' "$line" > "$CONSOLE_IN"
    done
    ;;
  wait)
    wait_for "${2:-com.apple.launchd}" "${3:-300}"
    ;;
  start)
    # Start QEMU + relay and return immediately (no auto-kill).
    kill_qemu
    boot_async >/dev/null
    echo "QEMU pid $(cat $PID_FILE) started; use 'pd_run.sh send <cmd>', 'pd_run.sh kill' to stop"
    ;;
  boot)
    kill_qemu
    boot_async >/dev/null
    echo "QEMU pid $(cat $PID_FILE); tailing $SERIAL_LOG (Ctrl-C to detach; 'pd_run.sh kill' to stop QEMU)"
    tail -F "$SERIAL_LOG"
    ;;
  probe)
    DURATION="${2:-300}"
    PATTERN="${3:-com.apple.launchd}"
    kill_qemu
    boot_async >/dev/null
    echo "QEMU pid $(cat $PID_FILE); waiting up to ${DURATION}s for: $PATTERN"
    if wait_for "$PATTERN" "$DURATION"; then
      rc=0
    else
      rc=$?
    fi
    echo "--- final serial size: $(stat -f '%z' "$SERIAL_LOG") bytes ---"
    echo "--- last 30 serial lines ---"
    tail -30 "$SERIAL_LOG" || true
    echo "--- screendump ---"
    shot >/dev/null || echo "(screendump failed)"
    kill_qemu
    exit $rc
    ;;
  *)
    echo "usage: $0 {probe [dur] [pattern]|start|boot|wait [pat] [t]|kill|shot [path]|sendkey <keys>|send <text>|sendraw <text>|interact}" >&2
    exit 2
    ;;
esac
