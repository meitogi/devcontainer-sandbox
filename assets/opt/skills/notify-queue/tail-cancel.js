#!/usr/bin/env node
// =============================================================================
// tail-cancel — detect "user clicked Cancel" via the transcript
// =============================================================================
//
// Spawned detached by hook.js when a PermissionRequest fires. Polls the
// transcript JSONL at `transcript_path` for an entry indicating the user
// rejected the tool use, and writes a `tool_cancelled` event to the queue
// so the host daemon can cancel the pending permission timer.
//
// Claude Code's PostToolUse hook does NOT fire on Cancel (tool never runs),
// so this is our only reliable way to detect the click within a few seconds.
//
// CANCEL PATTERN in the transcript (one of these arrives ~2 s after click) :
//   { type:"user", message:{ content:[{
//       type:"tool_result", is_error:true,
//       content:"The user doesn't want to proceed with this tool use. ..."
//   }] } }
//   { type:"user", message:{ content:[{
//       type:"text", text:"[Request interrupted by user for tool use]"
//   }] } }
//
// Either is sufficient — we look for whichever appears first.
//
// CLI : node tail-cancel.js <sid> <transcript_path>
// =============================================================================

const fs   = require('fs')
const path = require('path')

const [, , SID, TRANSCRIPT_PATH] = process.argv
if (!SID || !TRANSCRIPT_PATH) process.exit(0)

const QUEUE_DIR    = '/workspace/.devcontainer/notify/queue'
const POLL_MS      = 500
const TIMEOUT_MS   = 60_000

// Match-strings — short, specific enough to avoid false positives in normal
// tool_result output. The "doesn't want to proceed" wording is part of the
// canned Claude Code rejection message ; the "[Request interrupted by user
// for tool use]" is the matching user text turn that follows.
const REJECT_MARKERS = [
	"doesn't want to proceed",
	'[Request interrupted by user for tool use]'
]

let offset
try { offset = fs.statSync(TRANSCRIPT_PATH).size } catch { process.exit(0) }

const startedAt = Date.now()

const interval = setInterval(() => {
	if (Date.now() - startedAt > TIMEOUT_MS) {
		clearInterval(interval)
		return process.exit(0)
	}

	let size
	try { size = fs.statSync(TRANSCRIPT_PATH).size } catch { return }
	if (size <= offset) return

	let buf
	try {
		const fd = fs.openSync(TRANSCRIPT_PATH, 'r')
		buf = Buffer.alloc(size - offset)
		fs.readSync(fd, buf, 0, buf.length, offset)
		fs.closeSync(fd)
	} catch { return }

	// Advance offset to the byte after the last complete '\n' in the buffer.
	// Byte-only — same trick as the daemon's watcher (avoids JS string vs
	// UTF-8 byte index mismatches on multi-byte chars).
	const lastNlByte = buf.lastIndexOf(0x0A)
	if (lastNlByte < 0) return
	offset += lastNlByte + 1

	const text = buf.slice(0, lastNlByte).toString('utf8')
	for (const line of text.split('\n')) {
		if (!line) continue
		for (const marker of REJECT_MARKERS) {
			if (line.includes(marker)) {
				emitCancel()
				clearInterval(interval)
				return process.exit(0)
			}
		}
	}
}, POLL_MS)
// IMPORTANT : do NOT unref the interval — it's this process's only
// keep-alive handle. Unref'ing it makes Node exit immediately after
// the synchronous bootstrap, missing every poll.

// Don't keep the parent process alive (we're detached anyway).
process.on('SIGTERM', () => process.exit(0))
process.on('SIGINT',  () => process.exit(0))

function emitCancel() {
	const line = {
		ts:    new Date().toISOString(),
		sid:   SID,
		event: 'tool_cancelled'
	}
	try {
		fs.mkdirSync(QUEUE_DIR, { recursive: true })
		fs.appendFileSync(path.join(QUEUE_DIR, `${SID}.jsonl`), JSON.stringify(line) + '\n')
	} catch { /* swallow — best-effort */ }
}
