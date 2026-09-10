#!/usr/bin/env python3
# Renders the `docker build` rolling progress window release-check.sh's
# run_build() used to draw itself in bash (LOG.md § 2, session 2). Reads the
# build's stdout+stderr on stdin — already teed to $BUILD_LOG upstream, this
# script never touches that file — and redraws a status line (spinner +
# elapsed + last buildkit step) plus the last WIN lines, dimmed.
#
# Writes ONLY to /dev/tty, never to stdout: this process sits at the end of
# release-check.sh's own `exec > >(tee "$RUN_LOG")`, so anything printed to
# stdout would land in the run's self-transcript. No /dev/tty (agent, CI,
# redirected output) means no window at all — stdin is drained silently.
#
# select.select()'s timeout tells "no data yet" from "closed" without
# ambiguity, which is the one thing bash 3.2's `read -t` could not do (the
# ticker + end-of-stream sentinel this replaces existed only to work around
# that — see LOG.md § 2, "read -t ne renvoie pas la même chose").
import os
import re
import select
import sys
import time

WIN = 8
SPIN = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
STEP_RE = re.compile(r'^#\d+ .*\[\d+/\d+\]')


def draw(tty, tick, start, where, buf, maxw):
    el = int(time.monotonic() - start)
    tty.write('\033[%dF' % (WIN + 1))
    tty.write('\033[2K  \033[1;36m%s\033[0m %dm%02ds  \033[2;37m%.*s\033[0m\n'
               % (SPIN[tick % len(SPIN)], el // 60, el % 60, maxw, where))
    for line in buf:
        tty.write('\033[2K\033[2;37m    %.*s\033[0m\n' % (maxw, line))
    for _ in range(WIN - len(buf)):
        tty.write('\033[2K\n')
    tty.flush()


def main():
    fd = sys.stdin.fileno()
    try:
        tty = open('/dev/tty', 'w')
    except OSError:
        while os.read(fd, 65536):
            pass
        return

    try:
        maxw = max(os.get_terminal_size(tty.fileno()).columns - 8, 40)
    except OSError:
        maxw = 92

    tty.write('\n' * (WIN + 1))
    tty.flush()

    buf, where, pending, tick, eof = [], '', '', 0, False
    start = time.monotonic()
    last_draw = start
    while not eof:
        # A 0.1s select timeout only paces us while the pipe is quiet. A
        # chatty stage keeps data ready continuously, so select returns
        # instantly every time — gate redraws on wall-clock elapsed instead
        # of loop iterations, or the spinner spins at flood speed instead of
        # the steady ~10Hz the design calls for (LOG.md § 2).
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            chunk = os.read(fd, 65536)
            if not chunk:
                eof = True
                if pending:
                    buf.append(pending)
                    del buf[:-WIN]
            else:
                pending += chunk.decode('utf-8', 'replace')
                *lines, pending = pending.split('\n')
                for line in lines:
                    line = line.rstrip('\r')
                    if STEP_RE.match(line):
                        where = line
                    buf.append(line)
                    del buf[:-WIN]
        now = time.monotonic()
        if not eof and now - last_draw >= 0.1:
            tick += 1
            draw(tty, tick, start, where, buf, maxw)
            last_draw = now

    tty.write('\033[%dF' % (WIN + 1))
    for _ in range(WIN + 1):
        tty.write('\033[2K\n')
    tty.write('\033[%dF' % (WIN + 1))
    tty.flush()
    tty.close()


if __name__ == '__main__':
    main()
