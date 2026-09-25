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
# The redraw is `\r\033[nA` — carriage return, then CUU (cursor up n). NOT
# `\033[nF` (CPL, cursor previous line), which is what this drew until a Mac
# terminal was measured ignoring it: the window then never rewinds, so nine
# lines land ten times a second and a 90-second build prints thousands of them.
# CUU is honoured far more widely than CPL, and the CR in front makes the
# column explicit instead of relying on CPL's implicit return to column 1.
#
# If a terminal honours neither, DEVC_BUILD_WINDOW=0 turns the window off
# entirely and stdin is drained silently — the same path as no /dev/tty. The
# build keeps writing $BUILD_LOG either way: the window is a display, never the
# record.
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


def draw(tty, tick, start, where, buf, maxw, detw):
    el = int(time.monotonic() - start)
    tty.write('\r\033[%dA' % (WIN + 1))
    tty.write('\033[2K  \033[1;36m%s\033[0m %dm%02ds  \033[2;37m%.*s\033[0m\n'
               % (SPIN[tick % len(SPIN)], el // 60, el % 60, maxw, where))
    for line in buf:
        tty.write('\033[2K\033[2;37m    %.*s\033[0m\n' % (detw, line))
    for _ in range(WIN - len(buf)):
        tty.write('\033[2K\n')
    tty.flush()


def main():
    fd = sys.stdin.fileno()
    try:
        if os.environ.get('DEVC_BUILD_WINDOW') == '0':
            raise OSError
        tty = open('/dev/tty', 'w')
    except OSError:
        while os.read(fd, 65536):
            pass
        return

    # Two budgets, derived from the two format strings rather than from one
    # magic number. The header's visible prefix is 12 columns — two spaces, the
    # spinner, a space, up to six for the elapsed ("10m02s"), two spaces — and
    # the detail lines' is four. The +1 keeps the last column free: a line that
    # fills the terminal exactly wraps on most of them.
    #
    # This was one shared `columns - 8`, so the header ran 3 columns over (4 past
    # ten minutes) and WRAPPED. A wrapped frame is ten physical lines where the
    # rewind assumes nine, so the window drifted down by one and left a line
    # behind — per frame, ten times a second. Measured on a 139-column terminal
    # against a 131-character buildkit step: 142 columns for a 139-column frame.
    # The cursor sequence was never the problem; the arithmetic was.
    try:
        cols = os.get_terminal_size(tty.fileno()).columns
    except OSError:
        cols = 100
    maxw = max(cols - 13, 20)      # header:  12 prefix + 1 spare
    detw = max(cols - 5, 20)       # detail:   4 prefix + 1 spare

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
            draw(tty, tick, start, where, buf, maxw, detw)
            last_draw = now

    tty.write('\r\033[%dA' % (WIN + 1))
    for _ in range(WIN + 1):
        tty.write('\033[2K\n')
    tty.write('\r\033[%dA' % (WIN + 1))
    tty.flush()
    tty.close()


if __name__ == '__main__':
    main()
