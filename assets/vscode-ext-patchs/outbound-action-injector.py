#!/usr/bin/env python3
# @patch-category: notify
# @patch-files: extension.js
# @patch-sentinel: notify-queue-outbound-inject-v1
# @patch-sentinel: notify-queue-outbound-perm-log-v2
# @patch-sentinel: notify-queue-outbound-perm-settle-v2
# @patch-sentinel: notify-queue-outbound-session-track-v1
# @patch-summary: Watches an outbound JSONL file and replays permission answers into the
#   webview, so a notification can answer a prompt.
"""
Injects a reciprocal control channel into the Claude Code VS Code extension.

Two patches applied to `extension.js`:

1. **Outbound file watcher** — singleton, injected at the top of
   `PanelManager.setupPanel()`. Guarded by `this._outboundStarted` so only
   the first panel to open kicks it off. Polls `.devcontainer/logs/
   claude-code-vscode-ext-outbound.jsonl` every 200 ms; for each new line
   `{"cmd":"tool_permission_response","sessionId","requestId","behavior",
   "updatedInput","updatedPermissions"}` it looks up the target panel in
   `this.sessionPanels`, then posts `{type:"simulated_click", requestId,
   result:{...}}` to the webview via `panel.webview.postMessage`. The
   webview-side patch (`webview-simulated-click.py`) intercepts the
   `simulated_click`, finds the pending Gn permission-request instance
   by `channelId === requestId`, and calls `Q.accept(...)` / `Q.reject(...)` —
   which is exactly what a real Allow / Deny button click does. The response
   round-trips back to the ext through the canonical `onDidReceiveMessage`
   chokepoint (already logged by `user-action-observer.py`), so
   `inbound.jsonl` gets a `source:"user-action"` entry indistinguishable
   from a human click.

2. **sendRequest instrumentation** — Comms.sendRequest is patched to
   append pending / settled markers to `pending-perms.jsonl` whenever the
   request is a `tool_permission_request`. This makes outstanding
   permission requests observable to an external controller (which
   otherwise has no visibility into the ext→webview direction — the
   existing user-action-observer only captures webview→ext). The pending
   record shape is `{ts, sessionId, requestId, toolName, inputs, settled:
   false}`; the settle record is `{ts, sessionId, requestId, settled:true,
   outcome:"allow|deny"}`.

Anchor choice — why setupPanel top rather than the onDidReceiveMessage
site: user-action-observer.py already patches the onDidReceiveMessage
callback body. Patching the same site here would create a subtle
ordering dependency (alphabetical order puts outbound-* before user-*,
so we'd invalidate user-action-observer's regex). Injecting at the
opening brace of setupPanel is fully independent and survives
user-action-observer's own patch.

MARKER: `notify-queue-outbound-inject-v1`.

Exit codes
----------
- 0 : applied or already patched
- 1 : any regex miss (red banner + IMPACT_LINES)

Usage
-----
    outbound-action-injector.py [EXT_DIR]

If EXT_DIR omitted, autodiscovers the latest
~/.vscode-server/extensions/anthropic.claude-code-*.
"""

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


MARKER_WATCHER = 'notify-queue-outbound-inject-v1'
MARKER_PENDING = 'notify-queue-outbound-perm-log-v2'
MARKER_SETTLE = 'notify-queue-outbound-perm-settle-v2'
MARKER_TRACK_SID = 'notify-queue-outbound-session-track-v1'

# v1 → v2 record-shape change (v1 misnamed channelId as sessionId, breaking
# the reciprocal PanelManager.sessionPanels.get() lookup). Strip pre-existing
# v1 injections before applying v2 so the script is self-healing on rerun
# against a v1-patched extension.js.
MARKER_PENDING_V1 = 'notify-queue-outbound-perm-log-v1'
MARKER_SETTLE_V1 = 'notify-queue-outbound-perm-settle-v1'


def strip_v1_injection(content, marker_v1):
    """Remove an injection block introduced by v1 with shape:
       /*marker*/try{if(<req>?.type==="tool_permission_request"){...}}catch(_){};

    Locates the marker, then advances a brace counter from the `try{` opening
    to find the matching close, then consumes the trailing `catch(_){};`.
    Returns (new_content, stripped_count).
    """
    tag = f'/*{marker_v1}*/'
    tag_end_expected = len(tag)
    n = 0
    while True:
        i = content.find(tag)
        if i == -1:
            break
        # Anchor: `try{` immediately after the tag comment. Small tolerance
        # for stray whitespace introduced by an editor between tag and try.
        try_start = content.find('try{', i + tag_end_expected)
        if try_start == -1 or try_start - (i + tag_end_expected) > 4:
            # Unknown shape — bail rather than corrupt further
            break
        # Walk from try_start to find matching `}` closing the try block
        depth = 0
        j = try_start
        while j < len(content):
            ch = content[j]
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if depth != 0:
            break
        # After the try block: `catch(_){};` — consume it too.
        # Shape is fixed: `}catch(_){};`
        catch_start = j + 1
        catch_pat = 'catch(_){};'
        if content[catch_start:catch_start + len(catch_pat)] != catch_pat:
            # Unexpected shape — bail
            break
        end = catch_start + len(catch_pat)
        content = content[:i] + content[end:]
        n += 1
    return content, n

IMPACT_LINES = [
    "→ The outbound control channel will NOT be wired up.",
    "  External writes to claude-code-vscode-ext-outbound.jsonl will be",
    "  ignored; automated permission response injection will not work.",
    "  Pending permission tracking (pending-perms.jsonl) also lost.",
    "Likely cause: CLAUDE_CODE_VERSION was bumped and either the",
    "  setupPanel() signature or the sendRequest() shape drifted.",
    "  Inspect vendor/anthropic.claude-code/v<VER>/pretty/extension.js",
    "  around setupPanel and Comms.sendRequest, then update the regexes",
    "  in .devcontainer/claude/vscode-ext-patchs/outbound-action-injector.py.",
]


WATCHER_BLOCK = (
    '/*' + MARKER_WATCHER + '*/'
    'if(!this._outboundStarted){'
      'this._outboundStarted=true;'
      'try{'
        'const vscode=require("vscode");'
        'const wf=vscode.workspace.workspaceFolders?.[0]?.uri?.fsPath;'
        'if(wf){'
          'const path=require("path"),fs=require("fs");'
          'const dir=path.join(wf,".devcontainer","logs");'
          'const file=path.join(dir,"claude-code-vscode-ext-outbound.jsonl");'
          'const dbgFile=path.join(dir,"claude-code-vscode-ext-watcher-debug.jsonl");'
          # Tailable debug log gated by DEBUG=1 (or CLAUDE_OUTBOUND_DEBUG) —
          # keeps the JSONL clean in normal runtime. When off, dbg() is a
          # true no-op function (no fs syscalls per poll cycle).
          'const _dbgOn=(process.env.DEBUG==="1"||!!process.env.CLAUDE_OUTBOUND_DEBUG);'
          'const dbg=_dbgOn?(ev,extra)=>{try{fs.appendFileSync(dbgFile,JSON.stringify({ts:new Date().toISOString(),ev,...extra})+"\\n");}catch(_){}}:()=>{};'
          'try{fs.mkdirSync(dir,{recursive:true});fs.closeSync(fs.openSync(file,"a"));}catch(_){}'
          # Start reading from position 0 — reprocess any pre-existing lines.
          # Avoids the race where outbound-tester writes BEFORE setupPanel
          # runs its watcher init; without this, the pre-existing line is
          # never read (pos anchored at file end).
          'let pos=0;'
          'let carry="";'
          'this._outboundTimer=setInterval(()=>{'
            'let sz;try{sz=fs.statSync(file).size;}catch(_){return;}'
            'if(sz<pos){pos=0;carry="";dbg("truncated",{sz});}'
            'if(sz<=pos)return;'
            'dbg("change",{pos,sz});'
            'const buf=Buffer.alloc(sz-pos);let fd;'
            'try{fd=fs.openSync(file,"r");fs.readSync(fd,buf,0,buf.length,pos);}catch(e){dbg("read_fail",{err:String(e)});return;}'
            'finally{if(fd!==undefined){try{fs.closeSync(fd);}catch(_){}}}'
            'pos=sz;'
            'const chunk=carry+buf.toString("utf8");'
            'const lines=chunk.split("\\n");'
            'carry=lines.pop()||"";'
            'for(const line of lines){'
              'const t=line.trim();if(!t)continue;'
              'try{'
                'const cmd=JSON.parse(t);'
                'dbg("parsed",{cmd});'
                'if(cmd.cmd==="tool_permission_response"){'
                  'const knownSids=this.sessionPanels?[...this.sessionPanels.keys()]:[];'
                  'const p=this.sessionPanels?.get(cmd.sessionId);'
                  'if(!p){'
                    'dbg("lookup_miss",{sid:cmd.sessionId,knownSids});'
                    'this.output.warn(`[outbound-inject] no panel for sid=${cmd.sessionId} (known: ${knownSids.join(",")||"<empty>"})`);'
                    'continue;'
                  '}'
                  'dbg("lookup_hit",{sid:cmd.sessionId,rid:cmd.requestId});'
                  'const result={behavior:cmd.behavior,updatedInput:cmd.updatedInput??{},updatedPermissions:cmd.updatedPermissions??[]};'
                  'if(cmd.behavior==="deny")result.message=cmd.message??"denied";'
                  'try{'
                    'const posted=p.webview.postMessage({type:"from-extension",message:{type:"simulated_click",requestId:cmd.requestId,result}});'
                    'dbg("post",{sid:cmd.sessionId,rid:cmd.requestId,behavior:cmd.behavior,posted:!!posted});'
                    'this.output.info(`[outbound-inject] posted simulated_click sid=${cmd.sessionId} rid=${cmd.requestId} behavior=${cmd.behavior} posted=${!!posted}`);'
                  '}catch(e){'
                    'dbg("post_fail",{sid:cmd.sessionId,rid:cmd.requestId,err:String(e)});'
                    'this.output.warn(`[outbound-inject] postMessage failed: ${e?.message??e}`);'
                  '}'
                '}else{'
                  'dbg("unknown_cmd",{cmd});'
                  'this.output.warn(`[outbound-inject] unknown cmd: ${cmd.cmd}`);'
                '}'
              '}catch(e){dbg("parse_fail",{line:t,err:String(e)});this.output.warn(`[outbound-inject] parse failed: ${e?.message??e}`);}'
            '}'
          '},200);'
          'dbg("watcher_started",{file,dbgFile});'
          # Session boundary marker in pending-perms.jsonl. Reload wipes the
          # extension host; pending Gn instances get aborted (SDK reject),
          # but our settle-log injection only hooks the `resolve:` callback
          # — abort/reject never lands as `settled:true`. So old pending
          # records survive as ghosts. This marker gives outbound-tester a
          # cutoff: anything before the latest `session_boot` is stale.
          'try{'
            'const pendingFile=path.join(dir,"claude-code-vscode-ext-pending-perms.jsonl");'
            'fs.appendFileSync(pendingFile,JSON.stringify({ts:new Date().toISOString(),ev:"session_boot"})+"\\n");'
          '}catch(_){}'
          'this.output.info(`[outbound-inject] watcher started on ${file}, debug log at ${dbgFile}`);'
        '}'
      '}catch(e){this.output?.warn?.(`[outbound-inject] init failed: ${e?.message??e}`);}'
    '}'
)


def patch_watcher(content):
    """Inject the singleton file-watcher at the top of setupPanel(z,K,V,N){.
    Independent of user-action-observer.py which patches the onDidReceiveMessage
    call inside the method body.
    """
    if MARKER_WATCHER in content:
        n = content.count(MARKER_WATCHER)
        print(f"{YELLOW}[outbound-watcher]{RESET} extension.js — already patched ({n} site(s))")
        return content

    pat = re.compile(r'(setupPanel\([\w$]+,[\w$]+,[\w$]+,[\w$]+\)\{)')
    matches = list(pat.finditer(content))
    if not matches:
        banner("OUTBOUND WATCHER PATCH FAILED",
               "extension.js: setupPanel(z,K,V,N){ signature not found",
               IMPACT_LINES)
        sys.exit(1)
    if len(matches) > 1:
        # setupPanel appears exactly once as a method definition ; if we see
        # multiple, the regex is too permissive — abort loudly.
        banner("OUTBOUND WATCHER PATCH AMBIGUOUS",
               f"extension.js: setupPanel signature matched {len(matches)} times (expected 1)",
               IMPACT_LINES)
        sys.exit(1)

    # Direct char-index splice — re.sub would treat backslash escapes in
    # WATCHER_BLOCK as replacement escapes (`\n` → real newline mid-string,
    # breaking the JS). Same trap as user-action-observer.py documents.
    m = matches[0]
    new_content = content[:m.end()] + WATCHER_BLOCK + content[m.end():]
    print(f"{GREEN}[outbound-watcher]{RESET} extension.js — injected at setupPanel top")
    return new_content


def patch_sendrequest(content):
    """Instrument Comms.sendRequest to log tool_permission_request pending +
    settled events to pending-perms.jsonl. Two injections:
      A. Right after `let N=Y3();` → append pending record.
      B. Inside `{resolve:(Z)=>{...x(Z)...}` → append settled record.
    """
    # Self-healing: strip v1 injections before applying v2 shape. v1 misnamed
    # channelId as sessionId in the JSONL records; v2 fixes it.
    content, stripped_pending = strip_v1_injection(content, MARKER_PENDING_V1)
    content, stripped_settle = strip_v1_injection(content, MARKER_SETTLE_V1)
    if stripped_pending or stripped_settle:
        print(f"{YELLOW}[outbound-perm-log]{RESET} extension.js — stripped v1 injections (pending={stripped_pending}, settle={stripped_settle})")

    if MARKER_PENDING in content and MARKER_SETTLE in content:
        print(f"{YELLOW}[outbound-perm-log]{RESET} extension.js — already patched")
        return content

    # A. Pending log injection — match the sendRequest signature + `let N=Y3();`
    #    Captures: (1) full prefix, (2) sid var (z), (3) req obj var (K),
    #    (4) abort var (V), (5) requestId var (N).
    # `\w+\(\)` matches whichever minified name the requestId generator has
    # (Y3() on 2.1.145, Hs() on 2.1.202, likely to keep drifting) — the
    # surrounding sendRequest(...) { let ID = <fn>(); shape is the true anchor.
    pat_pending = re.compile(
        r'(sendRequest\(([\w$]+),([\w$]+),([\w$]+)\)\{let ([\w$]+)=[\w$]+\(\);)'
    )
    m_pending = pat_pending.search(content)
    if not m_pending:
        banner("OUTBOUND PENDING-LOG PATCH FAILED",
               "extension.js: sendRequest(<sid>,<req>,<abort>){let <rid>=<fn>();...} not found",
               IMPACT_LINES)
        sys.exit(1)

    sid_var = m_pending.group(2)
    req_var = m_pending.group(3)
    rid_var = m_pending.group(5)

    # sessionId = SDK UUID tracked by patch_track_session_id (stable, matches
    # PanelManager.sessionPanels key). channelId = sendRequest's 1st arg (the
    # short per-launch id, unstable across /debug relaunches). Both logged
    # under their accurate names — earlier v1 misnamed channelId as sessionId,
    # breaking the watcher's sessionPanels.get(sessionId) lookup.
    pending_inject = (
        '/*' + MARKER_PENDING + '*/'
        'try{'
          f'if({req_var}?.type==="tool_permission_request"){{'
            'const vs=require("vscode");'
            'const wf=vs.workspace.workspaceFolders?.[0]?.uri?.fsPath;'
            'if(wf){'
              'const path=require("path"),fs=require("fs");'
              'const file=path.join(wf,".devcontainer","logs","claude-code-vscode-ext-pending-perms.jsonl");'
              # `focused` / `active` snapshot at request time — lets consumers
              # know whether the user was even looking at VS Code when the
              # prompt fired (useful to auto-answer when the window has been
              # backgrounded for a while, or to prioritize a real click).
              'const ws=vs.window?.state;'
              f'const rec={{ts:new Date().toISOString(),sessionId:this._currentSessionId??null,channelId:{sid_var},requestId:{rid_var},toolName:{req_var}.toolName,inputs:{req_var}.inputs,focused:ws?.focused??null,active:ws?.active??null,settled:false}};'
              'try{fs.mkdirSync(path.dirname(file),{recursive:true});}catch(_){}'
              'fs.promises.appendFile(file,JSON.stringify(rec)+"\\n").catch(()=>{});'
            '}'
          '}'
        '}catch(_){};'
    )
    content = content[:m_pending.end()] + pending_inject + content[m_pending.end():]

    # B. Settle log injection — match the resolve callback inside the same
    #    sendRequest promise body. Anchor: `this.outstandingRequests.set(N,{resolve:(Z)=>{x(Z)}`
    #    where N is the requestId var captured in A.
    pat_settle = re.compile(
        r'(this\.outstandingRequests\.set\(' + re.escape(rid_var) + r',\{resolve:\(([\w$]+)\)=>\{)(' + r'[\w$]+\(\2\))(\})'
    )
    m_settle = pat_settle.search(content)
    if not m_settle:
        banner("OUTBOUND SETTLE-LOG PATCH FAILED",
               f"extension.js: outstandingRequests.set({rid_var},{{resolve:...}}) not found",
               IMPACT_LINES)
        sys.exit(1)

    resolve_arg = m_settle.group(2)   # Z
    resolve_call = m_settle.group(3)  # x(Z)

    settle_inject = (
        '/*' + MARKER_SETTLE + '*/'
        'try{'
          f'if({req_var}?.type==="tool_permission_request"){{'
            'const vs=require("vscode");'
            'const wf=vs.workspace.workspaceFolders?.[0]?.uri?.fsPath;'
            'if(wf){'
              'const path=require("path"),fs=require("fs");'
              'const file=path.join(wf,".devcontainer","logs","claude-code-vscode-ext-pending-perms.jsonl");'
              'const ws=vs.window?.state;'
              f'const rec={{ts:new Date().toISOString(),sessionId:this._currentSessionId??null,channelId:{sid_var},requestId:{rid_var},focused:ws?.focused??null,active:ws?.active??null,settled:true,outcome:{resolve_arg}?.result?.behavior??"unknown"}};'
              'fs.promises.appendFile(file,JSON.stringify(rec)+"\\n").catch(()=>{});'
            '}'
          '}'
        '}catch(_){};'
    )
    # Direct char-index splice — same re.sub escape-processing trap as the
    # watcher injection above. Splice at m_settle.start(1) end (right after
    # the resolve callback opening brace).
    inject_at = m_settle.start(3)  # start of `x(Z)`
    content = content[:inject_at] + settle_inject + content[inject_at:]

    print(f"{GREEN}[outbound-perm-log]{RESET} extension.js — instrumented sendRequest (sid={sid_var}, rid={rid_var})")
    return content


def patch_track_session_id(content):
    """Store the SDK session UUID on the Comms instance whenever
    `update_session_state` arrives. This is the same UUID PanelManager
    keys `sessionPanels` by — so pending-perms.jsonl records logged with
    `this._currentSessionId` will match the watcher's sessionPanels.get()
    lookup on the reciprocal side.

    Anchor: the `this.onSessionStateChanged?.(<expr>.sessionId,...)` call
    itself. Up to 2.1.220 it sits inline in the request dispatch chain
    (`else if(<msg>.request.type==="update_session_state")return ...`, so
    `<expr>` is `<msg>.request`); from 2.1.258 the dispatch entry became a
    bare acknowledgement and the notification moved into a dedicated
    state-reporting method, where `<expr>` is a plain local. Anchoring on
    the call rather than on its enclosing branch covers both.

    We inject `this._currentSessionId=<expr>.sessionId,` before the
    `onSessionStateChanged` call, using JS comma-operator semantics so the
    surrounding expression is unchanged.

    The tracked value is unset (undefined) until the first
    update_session_state arrives — which happens as soon as Claude
    receives its first API response. Perm requests only fire after the
    SDK has established a session, so in practice the tracked value is
    populated by the time we need it.
    """
    if MARKER_TRACK_SID in content:
        n = content.count(MARKER_TRACK_SID)
        print(f"{YELLOW}[outbound-session-track]{RESET} extension.js — already patched ({n} site(s))")
        return content

    pat = re.compile(
        r'(this\.onSessionStateChanged)\?\.\(([\w$]+(?:\.[\w$]+)*)\.sessionId,'
    )
    matches = list(pat.finditer(content))
    if not matches:
        banner("OUTBOUND SESSION-TRACK PATCH FAILED",
               'extension.js: this.onSessionStateChanged?.(<expr>.sessionId, ...) not found',
               IMPACT_LINES)
        sys.exit(1)
    if len(matches) > 1:
        banner("OUTBOUND SESSION-TRACK PATCH AMBIGUOUS",
               f"extension.js: onSessionStateChanged anchor matched {len(matches)} times (expected 1)",
               IMPACT_LINES)
        sys.exit(1)

    m = matches[0]
    msg_var = m.group(2)
    # `... || this._currentSessionId` guard: update_session_state can fire
    # with an empty/undefined sessionId during transitions (e.g., pre-SDK-
    # response state, or the "goodbye" fire when switching sessions —
    # webview-index.js: `if(J&&J!==X)Q.updateSessionState(J,"idle")`).
    # We only want to advance _currentSessionId to a NEW truthy value, never
    # overwrite a valid UUID with an empty string.
    inject = (
        f'/*{MARKER_TRACK_SID}*/'
        f'this._currentSessionId={msg_var}.sessionId||this._currentSessionId,'
    )
    # Splice at start of group 1 (`this.onSessionStateChanged`).
    inject_at = m.start(1)
    new_content = content[:inject_at] + inject + content[inject_at:]
    print(f"{GREEN}[outbound-session-track]{RESET} extension.js — tracking this._currentSessionId at onSessionStateChanged (expr={msg_var})")
    return new_content


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["extension.js"])
    js = ext_dir / "extension.js"

    print(f"Patching Claude Code extension at: {ext_dir}")

    content = js.read_text()
    original = content
    content = patch_watcher(content)
    content = patch_track_session_id(content)
    content = patch_sendrequest(content)

    if content != original:
        js.write_text(content)

    print(f"{GREEN}{BOLD}✓ outbound-action-injector patches complete{RESET}")


if __name__ == "__main__":
    main()
