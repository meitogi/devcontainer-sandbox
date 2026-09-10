#!/usr/bin/env python3
# @patch-category: notify
# @patch-files: webview/index.js
# @patch-sentinel: notify-queue-webview-sim-click-v2
# @patch-sentinel: notify-queue-webview-perm-reqid-callsite-v1
# @patch-sentinel: notify-queue-webview-perm-reqid-tag-v1
# @patch-summary: Webview half of the control channel: turns a replayed answer into the
#   same accept/reject a real button click performs.
"""
Injects a `simulated_click` interceptor into the Claude Code VS Code webview
bundle (`webview/index.js`). Companion to `outbound-action-injector.py`.

The extension-side watcher posts `{type:"from-extension", message:{type:
"simulated_click", requestId, result:{behavior, updatedInput,
updatedPermissions}}}` to `panel.webview.postMessage()` whenever an entry
lands in `.devcontainer/logs/claude-code-vscode-ext-outbound.jsonl`. This
patch intercepts that message on the WEBVIEW side (before the normal
message dispatcher runs) and calls `Q.accept(...)` / `Q.reject(...)` on the
matching pending `Gn` permission-request instance — which is the SAME
method the Allow/Deny button click handler invokes.

**Gn.channelId trap.** `Gn` constructor stores its first arg (the chat
channelId, e.g. `is7vqiuck6`) as `this.channelId`. The wire `requestId`
(e.g. `826f7870...`) is NOT stored on Gn anywhere — the mapping from
requestId to result happens via closure in `processRequestInner`.
Consequence: matching `Q.channelId === requestId` NEVER hits (they are
two different id spaces).

**Fix — three coordinated injections:**

  1. Callsite (`processRequestInner`): pass `$.requestId` as a 4th arg
     to `handleToolPermissionRequest`.
  2. Tag (`handleToolPermissionRequest`): stash `arguments[3]` on `Q`
     right after `let Q=new Gn(...)` → `Q._reqId = arguments[3]`.
  3. Intercept (`window.addEventListener("message")`): look up the
     pending Gn by `q?._reqId === _rid` (the wire requestId), not by
     channelId.

That gives each Gn a durable back-reference to the wire requestId, and
the intercept can then map an outbound tool_permission_response to the
right instance and call `Q.accept(...)` / `Q.reject(...)`. When Q
resolves, `Q.onResolved` fires and the extension receives the response
through the standard webview→ext channel (captured by
`user-action-observer.py` into `inbound.jsonl` with `source:"user-action"`,
indistinguishable from a real click).

Anchor for the intercept: the top-level `window.addEventListener("message",
(G)=>{...})` in the connection provider class `Xz1 extends zn`. `zn` owns
`fromHost` (message queue) and `permissionRequests` (array signal).

Markers:
  - `notify-queue-webview-perm-reqid-callsite-v1` — 4th-arg pass
  - `notify-queue-webview-perm-reqid-tag-v1` — Q._reqId stash
  - `notify-queue-webview-sim-click-v2` — message intercept (v1 matched
    on Q.channelId which never hit)

Exit codes
----------
- 0 : applied or already patched
- 1 : any regex miss (red banner + IMPACT_LINES)

Usage
-----
    webview-simulated-click.py [EXT_DIR]
"""

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import YELLOW, GREEN, BOLD, RESET, banner, resolve_ext_dir, check_files


MARKER_INTERCEPT = 'notify-queue-webview-sim-click-v2'
MARKER_CALLSITE = 'notify-queue-webview-perm-reqid-callsite-v1'
MARKER_TAG = 'notify-queue-webview-perm-reqid-tag-v1'

IMPACT_LINES = [
    "→ The webview will NOT intercept simulated_click messages from the",
    "  extension. External permission-response injection via outbound.jsonl",
    "  will still resolve ext-side promises (the tool runs), but the",
    "  webview UI prompt will not dismiss — orphaned Allow/Deny buttons.",
    "Likely cause: CLAUDE_CODE_VERSION was bumped and either the",
    "  window.addEventListener('message', ...) shape drifted, OR the",
    "  handleToolPermissionRequest callsite/definition shape drifted.",
    "Inspect vendor/anthropic.claude-code/v<VER>/pretty/webview-index.js",
    "  around the addEventListener('message', ...) call, the",
    "  processRequestInner tool_permission_request arm, and the",
    "  handleToolPermissionRequest body, then update the regexes in",
    "  .devcontainer/claude/vscode-ext-patchs/webview-simulated-click.py.",
]


def patch_perm_request_id_callsite(content):
    """At the processRequestInner callsite, pass $.requestId as a 4th arg
    to handleToolPermissionRequest so the request-response mapping can be
    reconstructed inside the callee.

    Anchor:
        let J = await this.handleToolPermissionRequest($.channelId,$.request,Z);

    Rewrites to:
        let J = await this.handleToolPermissionRequest($.channelId,$.request,Z,$.requestId);
    """
    if MARKER_CALLSITE in content:
        n = content.count(MARKER_CALLSITE)
        print(f"{YELLOW}[webview-perm-reqid-callsite]{RESET} webview/index.js — already patched ({n} site(s))")
        return content

    # Groups: (1) full prefix ending right before the closing `)`,
    #          (2) msg var (`$`), (3) signal var (Z), (4) the closing `)`.
    # `[\w$]+` because minified JS identifiers can start with `$` (which
    # Python `\w` does not include).
    pat = re.compile(
        r'(let [\w$]+=await this\.handleToolPermissionRequest\(([\w$]+)\.channelId,\2\.request,([\w$]+))(\))'
    )
    m = pat.search(content)
    if not m:
        banner("WEBVIEW PERM-REQID CALLSITE PATCH FAILED",
               "webview/index.js: handleToolPermissionRequest($.channelId,$.request,Z) callsite not found",
               IMPACT_LINES)
        sys.exit(1)

    msg_var = m.group(2)
    inject = f',/*{MARKER_CALLSITE}*/{msg_var}.requestId'
    inject_at = m.end(3)  # right after Z (before the closing `)`)
    new_content = content[:inject_at] + inject + content[inject_at:]
    print(f"{GREEN}[webview-perm-reqid-callsite]{RESET} webview/index.js — pass $.requestId as arg 4 (msg={msg_var})")
    return new_content


def patch_perm_request_id_tag(content):
    """Inside handleToolPermissionRequest, right after the Gn is created,
    stash the wire requestId (passed via arguments[3] from the patched
    callsite above) on the Gn instance so the message intercept can look
    it up.

    Anchor:
        let Q=new Gn($,eV(Z.toolName),eV(Z.inputs),eV(Z.suggestions));

    Injects:
        Q._reqId = arguments[3];

    Using arguments[3] rather than adding a formal param keeps the
    function signature unchanged — anything else calling this method
    with 3 args continues to work (Q._reqId becomes undefined).
    """
    if MARKER_TAG in content:
        n = content.count(MARKER_TAG)
        print(f"{YELLOW}[webview-perm-reqid-tag]{RESET} webview/index.js — already patched ({n} site(s))")
        return content

    # Class name (`Gn`→`LG` between 145 and 205) and sanitizer (`eV`→`A1`)
    # both drift. Anchor on the stable `.toolName/.inputs/.suggestions` field
    # names and capture the sanitizer via a backref so the same function
    # wraps all three fields (rules out unrelated `new X(...)` sites).
    pat = re.compile(
        r'(let ([\w$]+)=new [\w$]+\([\w$]+,([\w$]+)\([\w$]+\.toolName\),\3\([\w$]+\.inputs\),\3\([\w$]+\.suggestions\)\);)'
    )
    matches = list(pat.finditer(content))
    if not matches:
        banner("WEBVIEW PERM-REQID TAG PATCH FAILED",
               "webview/index.js: `let Q=new <Cls>($,<san>(Z.toolName),...)` not found",
               IMPACT_LINES)
        sys.exit(1)
    if len(matches) > 1:
        banner("WEBVIEW PERM-REQID TAG PATCH AMBIGUOUS",
               f"webview/index.js: Gn constructor pattern matched {len(matches)} times (expected 1)",
               IMPACT_LINES)
        sys.exit(1)

    m = matches[0]
    q_var = m.group(2)
    inject = f'/*{MARKER_TAG}*/{q_var}._reqId=arguments[3];'
    inject_at = m.end(1)  # right after the `;` closing the `let Q=new Gn(...)`
    new_content = content[:inject_at] + inject + content[inject_at:]
    print(f"{GREEN}[webview-perm-reqid-tag]{RESET} webview/index.js — stash arguments[3] on {q_var}._reqId")
    return new_content


def patch_message_intercept(content):
    """Rewrite:
        window.addEventListener("message",(G)=>{
          if(G.data.type==="from-extension")this.fromHost.enqueue(G.data.message)
        })
    into:
        window.addEventListener("message",(G)=>{
          if(G.data.type==="from-extension"){
            /*marker*/
            const m = G.data.message;
            if (m?.type === "simulated_click") { ...resolve pending Gn...; return; }
            this.fromHost.enqueue(m);
          }
        })

    Lookup uses `q?._reqId === _rid` — matches the wire requestId stashed
    by patch_perm_request_id_tag. v1 used `q?.channelId` which is the
    chat channelId, a different id space, so never matched.
    """
    if MARKER_INTERCEPT in content:
        n = content.count(MARKER_INTERCEPT)
        print(f"{YELLOW}[webview-sim-click]{RESET} webview/index.js — already patched ({n} site(s))")
        return content

    # Groups:
    #   1: full prefix ending at the closing paren of the from-extension cond
    #   2: event param var (G) — used in backrefs
    #   3: the closing `})` of the addEventListener call
    pat = re.compile(
        r'(window\.addEventListener\("message",\(([\w$]+)\)=>\{'
        r'if\(\2\.data\.type==="from-extension"\))'
        r'this\.fromHost\.enqueue\(\2\.data\.message\)'
        r'(\}\))'
    )
    m = pat.search(content)
    if not m:
        banner("WEBVIEW SIMULATED-CLICK PATCH FAILED",
               'webview/index.js: window.addEventListener("message",...) shape not found',
               IMPACT_LINES)
        sys.exit(1)

    ev_var = m.group(2)

    replacement = (
        m.group(1) + '{'
        '/*' + MARKER_INTERCEPT + '*/'
        f'const _m={ev_var}.data.message;'
        'if(_m?.type==="simulated_click"){'
          'console.log("[webview-sim-click] received",{rid:_m.requestId,behavior:_m.result?.behavior});'
          'try{'
            'const _rid=_m.requestId;'
            'const _pending=this.permissionRequests?.value||[];'
            'const _knownRids=_pending.map(q=>q?._reqId);'
            'const _Q=_pending.find(q=>q?._reqId===_rid);'
            'if(_Q){'
              'console.log("[webview-sim-click] matched Gn instance",{rid:_rid});'
              'const _r=_m.result;'
              'if(_r?.behavior==="allow"){'
                '_Q.accept(_r.updatedInput??{},_r.updatedPermissions??[]);'
                'console.log("[webview-sim-click] accept fired",{rid:_rid});'
              '}else{'
                '_Q.reject(_r?.message??"denied",false);'
                'console.log("[webview-sim-click] reject fired",{rid:_rid,msg:_r?.message});'
              '}'
            '}else{'
              'console.warn("[webview-sim-click] no pending Gn for requestId="+_rid,"known:",_knownRids);'
            '}'
          '}catch(e){console.warn("[webview-sim-click] failed:",e);}'
          'return;'
        '}'
        f'this.fromHost.enqueue(_m);'
        '}' + m.group(3)
    )

    new_content = content[:m.start()] + replacement + content[m.end():]
    print(f"{GREEN}[webview-sim-click]{RESET} webview/index.js — intercept injected (event var: {ev_var})")
    return new_content


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["webview/index.js"])
    js = ext_dir / "webview" / "index.js"

    print(f"Patching Claude Code webview at: {js}")

    content = js.read_text()
    original = content
    content = patch_perm_request_id_callsite(content)
    content = patch_perm_request_id_tag(content)
    content = patch_message_intercept(content)

    if content != original:
        js.write_text(content)

    print(f"{GREEN}{BOLD}✓ webview-simulated-click patches complete{RESET}")


if __name__ == "__main__":
    main()
