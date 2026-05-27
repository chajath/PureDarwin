#!/usr/bin/env python3
"""Console relay for pd_run.sh.

Connects to QEMU's serial chardev Unix socket, copies everything the
guest writes to /tmp/pd_serial.log, and forwards anything appearing on
/tmp/pd_console_in (a named pipe) into the guest.

Run as a background process from pd_run.sh boot_async.
"""
import errno
import os
import select
import socket
import sys
import time

SOCK = os.environ.get("PD_CONSOLE_SOCK", "/tmp/pd_console.sock")
LOG  = os.environ.get("PD_SERIAL_LOG",  "/tmp/pd_serial.log")
FIFO = os.environ.get("PD_CONSOLE_IN",  "/tmp/pd_console_in")
PID  = os.environ.get("PD_RELAY_PID",   "/tmp/pd_relay.pid")


def main() -> int:
    with open(PID, "w") as f:
        f.write(f"{os.getpid()}\n")

    # Wait for QEMU to create the socket.
    for _ in range(200):  # up to 20s
        if os.path.exists(SOCK):
            break
        time.sleep(0.1)
    if not os.path.exists(SOCK):
        print(f"pd_console_relay: socket {SOCK} never appeared", file=sys.stderr)
        return 2

    # Ensure FIFO exists.
    if os.path.exists(FIFO) and not os.path.exists(FIFO + ".keep"):
        # Re-create to drop stale readers/writers.
        try:
            os.unlink(FIFO)
        except OSError:
            pass
    if not os.path.exists(FIFO):
        os.mkfifo(FIFO, 0o600)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCK)
    sock.setblocking(False)

    # Open FIFO read-only NON-BLOCKING so select() can wait without writers.
    fifo_fd = os.open(FIFO, os.O_RDONLY | os.O_NONBLOCK)

    # Open log append-only.
    log_fd = os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)

    try:
        while True:
            rlist, _, _ = select.select([sock, fifo_fd], [], [], 1.0)
            if sock in rlist:
                try:
                    data = sock.recv(4096)
                except (BlockingIOError, InterruptedError):
                    data = b""
                if data == b"":
                    # remote closed
                    return 0
                os.write(log_fd, data)
            if fifo_fd in rlist:
                try:
                    data = os.read(fifo_fd, 4096)
                except BlockingIOError:
                    data = b""
                if data == b"":
                    # All writers closed; reopen to keep epoll/select happy.
                    os.close(fifo_fd)
                    fifo_fd = os.open(FIFO, os.O_RDONLY | os.O_NONBLOCK)
                    continue
                try:
                    sock.sendall(data)
                except OSError as e:
                    if e.errno in (errno.EPIPE, errno.ECONNRESET):
                        return 0
                    raise
    finally:
        try: os.close(fifo_fd)
        except OSError: pass
        try: os.close(log_fd)
        except OSError: pass
        try: sock.close()
        except OSError: pass
        try: os.unlink(PID)
        except OSError: pass


if __name__ == "__main__":
    sys.exit(main())
