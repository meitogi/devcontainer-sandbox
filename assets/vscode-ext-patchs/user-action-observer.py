#!/usr/bin/env python3
# @patch-category: notify
# @patch-files: extension.js
# @patch-sentinel: notify-queue-user-action-v3
# @patch-summary: Logs every webview to extension message to the output channel and to an
#   inbound JSONL file.
"""
Wraps the Claude Code VS Code extension's webview→ext message chokepoint
(`z.webview.onDidReceiveMessage` in `PanelManager.setupPanel()`) to log every
user → claude message to BOTH the « Claude VSCode » output channel (structured
`[user-action]` prefix) AND a JSONL file at
`<workspace>/.devcontainer/logs/claude-code-vscode-ext-inbound.jsonl`.
The parent dir is created at every container start by .devcontainer/post-start.sh,
which also wipes the JSONL on each boot (observation data, no retention).

PanelManager registers the same handler shape at MULTIPLE call sites (3 on
2.1.145 — primary panel setup + sidebar + secondary panel path). Each site
uses different minified variable names. We patch them all in one pass via
pat.subn + a per-match replacement builder.

Record shape (top-level): {ts, source, sessionId, channelId, pid, type, payload}.
sessionId is resolved via multi-path walk (9 known SDK-schema paths) — see
REPLACEMENT_TEMPLATE. channelId fallbacks through targetRequestId/requestId
when the message isn't a channel-bound one (yields a per-request id instead).
pid is best-effort across 6 paths on the Comms instance; null is acceptable
since sessionId is the routing key for downstream tools (notify-queue, etc).

Captured event types: io_message, response (= tool_permission_response
allow/deny/choices), launch_claude, interrupt_claude, close_channel,
cancel_request — every shape that webview→ext can emit.

Strategy
--------
- Idempotence marker: literal /*notify-queue-user-action-v1*/ inside the
  injected block. Probed at the top — no-op if present.
- Regex with backreferences captures the three minified names dynamically
  (panel, message param, comms instance), so the patch survives version bumps
  that rename `z` / `O` / `Z`.
- The original `this.output.info(\\`Received message from webview: …\\`)`
  log line is preserved verbatim — non-regression on Anthropic's observable
  behaviour.
- try/catch wraps the entire log block; any throw inside MUST NOT prevent
  the dispatcher (`comms?.fromClient(msg)`) from running, which is returned
  unconditionally as the last statement.
- JSONL append is fire-and-forget (no await, no blocking). Failures surface
  as `.warn` lines in the output channel, not as errors to the user.
- No workspace open → JSONL append is silently skipped; the structured
  channel line still appears.
- `require("vscode")` inline — avoids capturing a `vscode` binding via regex.

Exit codes
----------
- 0 : applied or already patched
- 1 : regex miss / file missing (red banner via _common.banner)

Usage
-----
    user-action-observer.py [EXT_DIR]

If EXT_DIR is omitted, auto-discovers the latest
~/.vscode-server/extensions/anthropic.claude-code-*-{arch} directory.
"""

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


MARKER = 'notify-queue-user-action-v3'

IMPACT_LINES = [
    "→ The user-action JSONL audit log will NOT be written.",
    "  Structured [user-action] lines in « Claude VSCode » output channel",
    "  are also lost.",
    "Likely cause: CLAUDE_CODE_VERSION was bumped and the onDidReceiveMessage",
    "  chokepoint shape drifted. Update the regex in",
    "  .devcontainer/claude/vscode-ext-patchs/user-action-observer.py.",
]


REPLACEMENT_TEMPLATE = (
    '%(panel)s.webview.onDidReceiveMessage((%(msg)s)=>{'
    'this.output.info(`Received message from webview: ${JSON.stringify(%(msg)s)}`);'
    '/*notify-queue-user-action-v3*/'
    'try{'
      'const ts=new Date().toISOString();'
      'const cid=%(msg)s?.channelId??%(msg)s?.targetRequestId??%(msg)s?.requestId??null;'
      'let sid=%(msg)s?.sessionId??%(msg)s?.session_id??%(msg)s?.request?.sessionId??%(msg)s?.request?.session_id??%(msg)s?.response?.sessionId??%(msg)s?.response?.session_id??%(msg)s?.message?.session_id??%(msg)s?.message?.sessionId??%(msg)s?.resume??null;'
      'if(sid==="")sid=null;'
      'if(!sid&&this.sessionPanels&&typeof this.sessionPanels.entries==="function"){try{for(const[k,v]of this.sessionPanels.entries()){if(v===%(panel)s){sid=k;break}}}catch(_){}}'
      'if(!sid)sid=this.activeSessionId??null;'
      'const pid=%(comms)s?.query?._claudeProcess?.pid??%(comms)s?.query?.process?.pid??%(comms)s?.query?.pid??%(comms)s?._claudeProcess?.pid??%(comms)s?.process?.pid??%(comms)s?.pid??null;'
      'const type=%(msg)s?.type??null;'
      'const record={ts,source:"user-action",sessionId:sid,channelId:cid,pid,type,payload:%(msg)s};'
      'this.output.info(`[user-action] ts=${ts} sessionId=${sid??"?"} channelId=${cid??"?"} pid=${pid??"?"} type=${type??"?"} payload=${JSON.stringify(%(msg)s)}`);'
      'const vscode=require("vscode");'
      'const wf=vscode.workspace.workspaceFolders;'
      'if(wf&&wf[0]){'
        'const path=require("path"),fs=require("fs");'
        'const file=path.join(wf[0].uri.fsPath,".devcontainer","logs","claude-code-vscode-ext-inbound.jsonl");'
        'fs.promises.appendFile(file,JSON.stringify(record)+"\\n").catch((e)=>this.output.warn(`[user-action] jsonl append failed: ${e?.message??e}`));'
      '}'
    '}catch(e){this.output.warn(`[user-action] log failed: ${e?.message??e}`);};'
    'return %(comms)s?.fromClient(%(msg)s)'
    '},null,this.disposables)'
)


def patch_inject_user_action_observer(content):
    """The chokepoint `z.webview.onDidReceiveMessage((O)=>{output.info(...),Z?.fromClient(O)})`
    appears at MULTIPLE call sites inside PanelManager (3 on 2.1.145 — primary
    panel setup, sidebar webview setup, secondary panel path). Each site uses
    its own minified names. We patch all matches, computing the replacement
    per-match so each rewrite uses ITS site's captured names.

    Idempotence: the regex matches only the ORIGINAL shape. After a successful
    patch run, re-running finds 0 matches and short-circuits (YELLOW).
    """
    pat = re.compile(
        r'([\w$]+)\.webview\.onDidReceiveMessage\(\(([\w$]+)\)=>\{'
        r'this\.output\.info\(`Received message from webview: \$\{JSON\.stringify\(\2\)\}`\),'
        r'([\w$]+)\?\.fromClient\(\2\)'
        r'\},null,this\.disposables\)'
    )
    matches = list(pat.finditer(content))
    if not matches:
        if MARKER in content:
            n = content.count(MARKER)
            print(f"{YELLOW}[user-action]{RESET} extension.js observer — already patched ({n} site(s))")
            return content
        banner("USER-ACTION OBSERVER PATCH FAILED",
               "extension.js: onDidReceiveMessage chokepoint pattern not found",
               IMPACT_LINES)
        sys.exit(1)

    # NOTE: a string-form repl in pat.sub() would have re.sub process backslash
    # escapes — so a source-level "\\n" would become a real newline mid-string-
    # literal, breaking the JS. Returning the replacement from a callable
    # bypasses that escape pass: re.sub inserts the returned bytes verbatim.
    def make_replacement(m):
        panel, msg, comms = m.groups()
        return REPLACEMENT_TEMPLATE % {'panel': panel, 'msg': msg, 'comms': comms}

    new_content, n = pat.subn(make_replacement, content)
    captures = ', '.join(f'{p}/{m}/{c}' for p, m, c in (mt.groups() for mt in matches))
    print(f"{GREEN}[user-action]{RESET} extension.js observer — injected at {n} site(s) ({captures})")
    return new_content


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["extension.js"])
    js = ext_dir / "extension.js"

    print(f"Patching Claude Code extension at: {ext_dir}")

    content = js.read_text()
    original = content
    content = patch_inject_user_action_observer(content)

    if content != original:
        js.write_text(content)

    print(f"{GREEN}{BOLD}✓ user-action-observer patches complete{RESET}")


if __name__ == "__main__":
    main()
