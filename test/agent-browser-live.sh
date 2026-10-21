#!/usr/bin/env bash
# The agent browser's proxy in front of a REAL Chromium — the sidecar image,
# built and run on whatever Docker daemon answers (the host's, or the nested
# dind from inside the devcontainer). A node container holds a network
# namespace and serves a page with a worker on 5173 ; the sidecar joins it,
# loads the page through its file channel ; a third container runs the proxy's
# node tests with the live half on, then visual-loop's own cdp.mjs through the
# proxy's browser-level door. Then visual-loop's player harness (e2e.mjs with
# meta.player) plays test/player/game.html through the same proxy : keys, pads,
# shot, video with sound under --mute-audio, screencast fallback, fps. Seven
# assertions, documented in TESTING.md.
#
#   bash test/agent-browser-live.sh      # needs docker ; ~2 min the first time (apt chromium)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/assets/opt/skills/agent-browser"
IMG=agent-browser-sidecar:test
NODE_IMG=node:24-slim

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
ko() { FAIL=$((FAIL+1)); printf '  ✘ %s\n' "$1" >&2; return 1; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "✗ needs a Docker daemon" >&2; exit 2; }
# Under the nested daemon every -v source is resolved on ITS filesystem : only
# paths under /workspace exist on both sides (run-all.sh sets TMPDIR there).
L=$(mktemp -d "${TMPDIR:-/tmp}/ab-live.XXXXXX")
mkdir -p "$L/ctl" "$L/www"
cat >"$L/www/index.html" <<'EOH'
<!doctype html><title>agent-browser live</title>
<body style="margin:0;background:#123;color:#fff;font:24px sans-serif"><h1 id="h">agent-browser live</h1>
<canvas id="c" width="320" height="200"></canvas>
<script>
const w = new Worker('w.js'); w.onmessage = e => { document.getElementById('h').textContent = 'worker says ' + e.data; };
w.postMessage('hi');
const ctx = document.getElementById('c').getContext('2d'); let t = 0;
(function draw(){ ctx.fillStyle = `hsl(${t++ % 360},80%,50%)`; ctx.fillRect(0,0,320,200); requestAnimationFrame(draw); })();
</script>
EOH
echo "onmessage = e => postMessage(e.data + ' back');" >"$L/www/w.js"
cp "$REPO/test/player/game.html" "$L/www/game.html"
cat >"$L/www/serve.mjs" <<'EOS'
import http from 'node:http'; import fs from 'node:fs';
http.createServer((req, res) => {
  const f = '/www' + (req.url === '/' ? '/index.html' : req.url.split('?')[0]);
  if (!fs.existsSync(f)) { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'Content-Type': f.endsWith('.js') ? 'text/javascript' : 'text/html' }).end(fs.readFileSync(f));
}).listen(5173, '127.0.0.1');
EOS
NET=ab-live-net-$$; SIDE=ab-live-side-$$
cleanup() { docker rm -f "$NET" "$SIDE" >/dev/null 2>&1; rm -rf "$L"; }
trap cleanup EXIT

echo "== build =="
docker build -q -t "$IMG" "$SKILL/sidecar" >"$L/build.log" 2>&1
check "the sidecar image builds (debian chromium + Mesa)" "[ \$? -eq 0 ] || { tail -5 '$L/build.log' >&2; false; }"

echo "== the sidecar loads the page =="
docker run -d --name "$NET" -v "$L/www:/www" "$NODE_IMG" node /www/serve.mjs >/dev/null
docker run -d --name "$SIDE" --network "container:$NET" --cap-drop ALL --security-opt no-new-privileges:true \
	-v "$L/ctl:/ctl" -e AGENT_BROWSER_CDP_PORT=9323 "$IMG" >/dev/null
sleep 2; printf '%s up http://localhost:5173/\n' "$(date +%s%N)" >"$L/ctl/cmd"
up=1
for _ in $(seq 1 60); do
	docker exec "$NET" node -e "fetch('http://127.0.0.1:9323/json/list').then(r=>r.json()).then(l=>process.exit(l.some(t=>t.type==='page'&&t.url.startsWith('http://localhost:5173'))?0:1)).catch(()=>process.exit(1))" 2>/dev/null && { up=0; break; }
	sleep 1
done
check "the sidecar answers 'running' and Chromium lists the page on CDP" "[ $up -eq 0 ] && grep -q ' running ' '$L/ctl/state'"

echo "== the proxy, live =="
docker run --rm --network "container:$NET" -v "$REPO:/repo" -e AGENT_BROWSER_TEST_CDP=127.0.0.1:9323 "$NODE_IMG" \
	node --test /repo/assets/opt/skills/agent-browser/host/cdp-proxy.test.mjs >"$L/node.out" 2>&1
check "the 10 proxy tests pass in front of a real Chromium (live half included)" "grep -q '^ℹ fail 0' '$L/node.out' && grep -q '^ℹ skipped 0' '$L/node.out' && grep -q '^ℹ pass 10' '$L/node.out'" \
	|| tail -30 "$L/node.out" >&2

echo "== visual-loop's cdp.mjs through the browser door =="
docker run --rm --network "container:$NET" -v "$REPO:/repo" -v "$L:/live" \
	-e CDP_HOST=127.0.0.1 -e CDP_PORT=9223 -e CDP_LOCK_DIR=/tmp -e CDP_APP_URL=http://localhost:5173/ -e CDP_APP_ROOT=h1 \
	-e AGENT_BROWSER_ORIGINS=http://localhost:5173 "$NODE_IMG" bash -c '
	node /repo/assets/opt/skills/agent-browser/host/cdp-proxy.mjs serve --listen 127.0.0.1:9223 --upstream 127.0.0.1:9323 >/live/proxy.log 2>&1 &
	sleep 1
	node /repo/assets/opt/skills/visual-loop/scripts/cdp.mjs shot http://localhost:5173/ --out /live/shot.png >/live/shot.out 2>&1; echo "shot=$?" >>/live/rc
	node /repo/assets/opt/skills/visual-loop/scripts/cdp.mjs eval "document.getElementById(\"h\").textContent" >/live/eval.out 2>&1; echo "eval=$?" >>/live/rc
	node /repo/assets/opt/skills/visual-loop/scripts/front.mjs --grace 0 >/live/front.out 2>&1; echo "front=$?" >>/live/rc
	kill %1' >/dev/null 2>&1
check "cdp.mjs shot / eval and front.mjs work unchanged through the proxy (PNG written, worker reply read, tab visible)" \
	"grep -qx 'shot=0' '$L/rc' && grep -qx 'eval=0' '$L/rc' && grep -qx 'front=0' '$L/rc' && [ -s '$L/shot.png' ] && grep -q 'worker says hi back' '$L/eval.out'" \
	|| { cat "$L/rc" "$L/shot.out" "$L/eval.out" "$L/front.out" >&2; }

echo "== the player harness through the proxy =="
# The sidecar runs with --mute-audio (AGENT_BROWSER_AUDIO unset) : the RECORD
# scenario is the proof that the Web Audio tap records sound anyway.
mkdir -p "$L/proofs"
docker run --rm --network "container:$NET" -v "$REPO:/repo" -v "$L:/live" \
	-e CDP_HOST=127.0.0.1 -e CDP_PORT=9223 -e CDP_LOCK_DIR=/tmp -e CDP_APP_URL=http://localhost:5173/ \
	-e AGENT_BROWSER_ORIGINS=http://localhost:5173 -e NO_COLOR=1 "$NODE_IMG" bash -c '
	node /repo/assets/opt/skills/agent-browser/host/cdp-proxy.mjs serve --listen 127.0.0.1:9223 --upstream 127.0.0.1:9323 >/live/proxy2.log 2>&1 &
	sleep 1
	node /repo/assets/opt/skills/visual-loop/scripts/e2e.mjs --suite /repo/test/player/game.suite.mjs --proofs /live/proofs >/live/e2e.out 2>&1; echo "e2e=$?" >/live/rc2
	kill %1' >/dev/null 2>&1
RUN=$(find "$L/proofs" -mindepth 1 -maxdepth 1 -type d | head -1)
check "e2e.mjs plays the fake game : keys, pads, shot, record, screencast, fps — 6 pass" \
	"grep -qx 'e2e=0' '$L/rc2' && grep -q '6 pass · 0 fail' '$L/e2e.out'" \
	|| { cat "$L/e2e.out" "$L/proxy2.log" >&2; }
check "the run folder holds run.json, index.md, the PNG, the video and the screencast" \
	"[ -n '$RUN' ] && [ -s '$RUN/run.json' ] && grep -q '^# /repo/test/player/game.suite.mjs' '$RUN/index.md' && ls '$RUN'/*-shot-canvas.png '$RUN'/*-record-sound.* '$RUN'/*-screencast-silent.frames/00000.jpg >/dev/null" \
	|| ls -R "$L/proofs" >&2
# ffprobe / ffmpeg from the machine running this suite ; the devcontainer has them.
VIDEO=$(ls "$RUN"/*-record-sound.mp4 "$RUN"/*-record-sound.webm 2>/dev/null | head -1)
if command -v ffprobe >/dev/null 2>&1; then
	ffprobe -v error -show_entries stream=codec_type,codec_name -of csv=p=0 "$VIDEO" >"$L/streams" 2>&1
	ffmpeg -nostats -i "$VIDEO" -map 0:a -af volumedetect -f null - 2>"$L/vol"
	MAXDB=$(sed -n 's/.*max_volume: \(-\?[0-9.]*\) dB/\1/p' "$L/vol")
	# Observed on the running Chromium, not assumed from the default.
	docker exec "$SIDE" sh -c "cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\\0' ' '" >"$L/cmdline"
	check "the recording has a video and an audio stream, and the audio is not silent under --mute-audio (max ${MAXDB:-?} dB > -30)" \
		"grep -q -- '--mute-audio' '$L/cmdline' && grep -q ',video' '$L/streams' && grep -q ',audio' '$L/streams' && awk -v v='${MAXDB:--200}' 'BEGIN{exit !(v > -30)}'" \
		|| cat "$L/streams" "$L/vol" >&2
else
	echo "  - skipped : no ffprobe here, the audio level of $VIDEO is not measured" >&2
fi
[ -n "${AB_LIVE_KEEP:-}" ] && { mkdir -p "$AB_LIVE_KEEP" && cp -r "$RUN" "$AB_LIVE_KEEP/"; echo "  proofs kept in $AB_LIVE_KEEP/$(basename "$RUN")"; }

echo
echo "agent-browser-live: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
