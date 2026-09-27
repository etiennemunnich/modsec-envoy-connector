#!/usr/bin/env python3
"""Run a command fully detached (double fork + setsid) so demo processes
survive the shell that started them (macOS has no `setsid` binary).

usage: daemonize.py <logfile> <pidfile> -- <command> [args...]
Writes the command's PID to <pidfile> before returning.
"""

import os
import sys


def main():
    if len(sys.argv) < 5 or sys.argv[3] != "--":
        sys.exit(__doc__)
    logfile, pidfile, cmd = sys.argv[1], sys.argv[2], sys.argv[4:]
    r, w = os.pipe()
    if os.fork() > 0:
        os.close(w)
        pid = os.read(r, 32).decode().strip()
        if not pid:
            sys.exit("daemonize: child failed to start")
        with open(pidfile, "w") as f:
            f.write(pid + "\n")
        return
    os.close(r)
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    devnull = os.open(os.devnull, os.O_RDONLY)
    log = os.open(logfile, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(devnull, 0)
    os.dup2(log, 1)
    os.dup2(log, 2)
    os.write(w, str(os.getpid()).encode())
    os.close(w)
    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        os.write(2, f"daemonize: exec {cmd[0]} failed: {e}\n".encode())
        os._exit(127)


if __name__ == "__main__":
    main()
