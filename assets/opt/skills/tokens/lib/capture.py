#!/usr/bin/env python3
# tokens skill — parse transcript, compute token delta, write JSONL event.
# Ported from .devcontainer/skills/hours.local/hours-log.sh (python3 block, lines 22-120).

import argparse
import json
import os
import sys
from datetime import datetime, timezone

PRICING_FALLBACK = {
    'claude-opus-4-7':   {'in': 5.00, 'cache_read': 0.50, 'cache_create': 10.00, 'out': 25.00},
    'claude-opus-4-6':   {'in': 5.00, 'cache_read': 0.50, 'cache_create': 10.00, 'out': 25.00},
    'claude-opus-4-5':   {'in': 5.00, 'cache_read': 0.50, 'cache_create': 10.00, 'out': 25.00},
    'claude-opus-4-1':   {'in': 15.00, 'cache_read': 1.50, 'cache_create': 30.00, 'out': 75.00},
    'claude-sonnet-4-6': {'in': 3.00, 'cache_read': 0.30, 'cache_create': 6.00,  'out': 15.00},
    'claude-sonnet-4-5': {'in': 3.00, 'cache_read': 0.30, 'cache_create': 6.00,  'out': 15.00},
    'claude-sonnet-4':   {'in': 3.00, 'cache_read': 0.30, 'cache_create': 6.00,  'out': 15.00},
    'claude-haiku-4-5':  {'in': 1.00, 'cache_read': 0.10, 'cache_create': 2.00,  'out': 5.00},
    'claude-haiku-3-5':  {'in': 0.80, 'cache_read': 0.08, 'cache_create': 1.60,  'out': 4.00},
    'claude-haiku-3':    {'in': 0.25, 'cache_read': 0.03, 'cache_create': 0.50,  'out': 1.25},
}
FALLBACK_MODEL = 'claude-opus-4-7'

TOKENS_KEYS = ('in', 'cache_read', 'cache_create', 'out')


def read_previous_total(log_path):
    prev = {k: 0 for k in TOKENS_KEYS}
    if not os.path.exists(log_path):
        return prev
    with open(log_path) as f:
        for line in reversed(f.readlines()):
            try:
                d = json.loads(line)
                if 'tokens_total' in d:
                    for k in TOKENS_KEYS:
                        prev[k] = d['tokens_total'].get(k, 0)
                    return prev
            except Exception:
                pass
    return prev


def parse_transcript(transcript_path):
    total = {k: 0 for k in TOKENS_KEYS}
    model = 'unknown'
    with open(transcript_path) as f:
        for line in f:
            try:
                d = json.loads(line)
                msg = d.get('message', {}) or {}
                u = msg.get('usage', {}) or {}
                if u.get('input_tokens') is not None:
                    total['in'] += u.get('input_tokens', 0)
                    total['cache_read'] += u.get('cache_read_input_tokens', 0)
                    total['cache_create'] += u.get('cache_creation_input_tokens', 0)
                    total['out'] += u.get('output_tokens', 0)
                m = msg.get('model', '')
                if m:
                    model = m
            except Exception:
                pass
    return total, model


def price_for(model):
    for key, prices in PRICING_FALLBACK.items():
        if model.startswith(key):
            return prices
    return PRICING_FALLBACK[FALLBACK_MODEL]


def calc_usd(tokens, prices):
    return (
        tokens['in'] * prices['in']
        + tokens['cache_read'] * prices['cache_read']
        + tokens['cache_create'] * prices['cache_create']
        + tokens['out'] * prices['out']
    ) / 1_000_000


def write_config(project_root, project_id, host_workspace_path, now_iso):
    cfg_dir = os.path.join(project_root, '.claude', 'tokens')
    os.makedirs(cfg_dir, exist_ok=True)
    cfg_path = os.path.join(cfg_dir, 'config.json')
    display_path = host_workspace_path or project_root
    title = os.path.basename(display_path.rstrip('/')) or display_path
    if os.path.exists(cfg_path):
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
        except Exception:
            cfg = {}
        cfg['last_seen'] = now_iso
    else:
        cfg = {
            'project_id': project_id,
            'title': title,
            'subtitle': '',
            'host_workspace_path': host_workspace_path or '',
            'container_workspace_path': project_root,
            'first_seen': now_iso,
            'last_seen': now_iso,
        }
    tmp = cfg_path + '.new'
    with open(tmp, 'w') as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, cfg_path)
    return cfg


def append_project_registry(project_id, host_workspace_path, project_root, title, now_iso):
    reg_dir = os.path.expanduser('~/.claude/tokens')
    os.makedirs(reg_dir, exist_ok=True)
    reg_path = os.path.join(reg_dir, 'projects.jsonl')
    seen = False
    if os.path.exists(reg_path):
        with open(reg_path) as f:
            for line in f:
                try:
                    if json.loads(line).get('project_id') == project_id:
                        seen = True
                        break
                except Exception:
                    pass
    if seen:
        return
    entry = {
        'ts': now_iso,
        'project_id': project_id,
        'host_workspace_path': host_workspace_path or '',
        'project_root': project_root or '',
        'title': title,
    }
    with open(reg_path, 'a') as f:
        f.write(json.dumps(entry) + '\n')


def log_error(msg):
    try:
        err_dir = os.path.expanduser('~/.claude/tokens')
        os.makedirs(err_dir, exist_ok=True)
        with open(os.path.join(err_dir, 'capture-errors.log'), 'a') as f:
            f.write('{} {}\n'.format(datetime.now(timezone.utc).isoformat(), msg))
    except Exception:
        pass


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--session', required=True)
    p.add_argument('--transcript', required=True)
    p.add_argument('--project-root', required=True)
    p.add_argument('--project-id', required=True)
    p.add_argument('--host-workspace', default='')
    args = p.parse_args()

    if not os.path.isfile(args.transcript):
        log_error('transcript not found: {}'.format(args.transcript))
        return 0

    now = datetime.now(timezone.utc)
    now_iso = now.strftime('%Y-%m-%dT%H:%M:%SZ')
    month = now.strftime('%Y-%m')

    log_dir = os.path.join(args.project_root, '.claude', 'tokens', 'logs', month)
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, args.session + '.jsonl')

    prev = read_previous_total(log_path)
    total, model = parse_transcript(args.transcript)
    delta = {k: total[k] - prev.get(k, 0) for k in TOKENS_KEYS}
    prices = price_for(model)

    event = {
        'ts': now_iso,
        'session': args.session,
        'model': model,
        'project_root': args.project_root,
        'tokens': delta,
        'cost_usd': round(calc_usd(delta, prices), 4),
        'tokens_total': total,
        'cost_usd_total': round(calc_usd(total, prices), 4),
    }
    with open(log_path, 'a') as f:
        f.write(json.dumps(event) + '\n')

    cfg = write_config(args.project_root, args.project_id, args.host_workspace, now_iso)
    append_project_registry(args.project_id, args.host_workspace, args.project_root, cfg.get('title', ''), now_iso)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        log_error('unhandled: {}'.format(e))
        sys.exit(0)
