#!/usr/bin/env bash
# Iteration harness for PureDarwin in QEMU.
#
# Subcommands:
#   probe [duration] [pattern]   boot, wait until match/panic/timeout, exit
#   boot                         boot and stream serial to stdout
#   wait [pattern] [t]           wait until serial matches; default = launchd-up
#   shot [path]                  screendump current QEMU display to PNG
#   sendkey <keys...>            forward sendkey commands to QEMU monitor
#   kill                         stop any running QEMU and clean up
#
# Globals exposed:
#   /tmp/pd_serial.log   live serial console capture
#   /tmp/pd_qemu.pid     QEMU pid file
#   /tmp/pd_mon.sock     QEMU monitor socket (text protocol)
#   /tmp/pd_screen.png   most recent screendump
#
# Exit codes from probe:
#   0  pattern matched
#   1  timeout
#   2  panic detected
set -euo pipefail

PROJ_DIR="$HOME/PureDarwin/userland/boot"
RAW="$PROJ_DIR/pd_17_4_modded.raw"
VMDK="$PROJ_DIR/pd_17_4_modded.vmdk"
SERIAL_LOG="/tmp/pd_serial.log"
MONITOR_SOCK="/tmp/pd_mon.sock"
SCREENSHOT_PPM="/tmp/pd_screen.ppm"
SCREENSHOT_PNG="/tmp/pd_screen.png"
PID_FILE="/tmp/pd_qemu.pid"

QEMU=qemu-system-x86_64
QEMU_ARGS=(
  -m 2G
  -cpu Penryn
  -drive "file=$VMDK,format=vmdk,if=ide"
  -netdev user,id=net0,hostfwd=tcp::2222-:22
  -device rtl8139,netdev=net0
  -display none
  -chardev "file,path=$SERIAL_LOG,id=s0"
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
  rm -f "$MONITOR_SOCK"
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
  rm -f "$MONITOR_SOCK" "$PID_FILE"
  "$QEMU" "${QEMU_ARGS[@]}" >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"

  for _ in $(seq 1 50); do
    [ -S "$MONITOR_SOCK" ] && break
    sleep 0.1
  done

  # Chameleon shows a "boot:" prompt and waits forever w/o a Timeout key.
  # Send Enter twice (a few seconds apart) to start the default boot.
  ( sleep 4; mon "sendkey ret" >/dev/null;
    sleep 4; mon "sendkey ret" >/dev/null ) &
  echo "$pid"
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
  wait)
    wait_for "${2:-com.apple.launchd}" "${3:-300}"
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
    echo "usage: $0 {probe [dur] [pattern]|boot|wait [pat] [t]|kill|shot [path]|sendkey <keys>}" >&2
    exit 2
    ;;
esac
