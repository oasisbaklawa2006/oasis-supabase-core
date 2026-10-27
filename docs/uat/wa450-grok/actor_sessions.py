#!/usr/bin/env python3
"""Generate isolated Grok persona prompts; optionally run simulated persona sessions.

This script does NOT connect to WhatsApp, Supabase or a browser. A Grok session's
output is simulated test content, never evidence that an actual action occurred.
"""
import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCENARIOS = {r['test_id']: r for r in csv.DictReader((ROOT/'TEST_MATRIX.csv').open(encoding='utf-8'))}
ACTORS = {
    'CUSTOMER': 'Consenting business buyer: Hinglish, interruptions, corrections, realistic questions, no fake real orders.',
    'SALES': 'Consultative B2B sales associate: grounded catalog, SKU/MOQ confirmation, no fabricated offers.',
    'SUPPORT': 'Support employee: clarify, escalate, handle complaints; do not perform MFA-only closure.',
    'FINANCE': 'Read-only finance checker: check synthetic estimates, no real payment or credit authorization.',
    'OPERATIONS': 'Read-only factory/dispatch employee: trace non-fulfilling TEST draft, no live dispatch.',
    'QA': 'Independent skeptical auditor: question unsupported claims, ask for exact signed/provider evidence.'
}

def build(actor, test_id):
    s = SCENARIOS[test_id]
    return '\n'.join([
        'You are an isolated SIMULATED_ONLY UAT actor. You have NO production account, phone or tool access.',
        f'Actor: {actor} — {ACTORS[actor]}',
        f'Test case: {test_id}',
        f'Test objective: {s["scenario"]}',
        f'Expected result: {s["expected"]}',
        'Produce only a role-play transcript/message variations and the evidence that a real tester must capture.',
        'Do not claim to execute a message, click, webhook, API call, AAL2 verification, screenshot or SQL query.',
        'Do not request or echo secrets, numbers, emails, customer identifiers, OTPs, tokens or session cookies.',
        'Return JSON with keys actor, test_id, proposed_messages, expected_observations, missing_real_world_tools,',
        'and claim_type: SIMULATED_ONLY. Max 6 short proposed messages. Never output PASS.'
    ])

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--actor', choices=list(ACTORS), required=True)
    p.add_argument('--test', choices=sorted(SCENARIOS), required=True)
    p.add_argument('--run-grok', action='store_true', help='Calls installed authenticated Grok CLI ONLY for simulated scenario generation, not live operations')
    p.add_argument('--max-seconds', type=int, default=100)
    a=p.parse_args()
    prompt=build(a.actor,a.test)
    if not a.run_grok:
        print(prompt)
        return
    grok=shutil.which('grok')
    if not grok:
        print('BLOCKED: Grok CLI not installed/logged in. Output prompt without --run-grok and paste to Grok.', file=sys.stderr)
        sys.exit(2)
    if os.environ.get('GROK_UAT_MODE','OBSERVE') not in ('OBSERVE','SIMULATED'):
        print('BLOCKED: --run-grok only available in OBSERVE/SIMULATED mode', file=sys.stderr)
        sys.exit(2)
    r=subprocess.run([grok,'-p',prompt,'--output-format','json'],text=True,capture_output=True,timeout=a.max_seconds,cwd=ROOT,check=False)
    if r.returncode:
        print('BLOCKED: Grok exited with status',r.returncode, file=sys.stderr)
        sys.exit(3)
    try:
        response=json.loads(r.stdout)
        text=response.get('text','')
        data=json.loads(text) if isinstance(text,str) and text.lstrip().startswith('{') else {'simulated_text':text}
    except json.JSONDecodeError:
        data={'simulated_text':r.stdout[:10000]}
    content=json.dumps(data,ensure_ascii=False)
    if re.search(r'(?i)\bBearer\s+[\w.-]{15,}|\b\w+@\w+\.\w+\b|(?<!\w)\+?[1-9]\d{9,14}(?!\w)',content):
        print('BLOCKED: output looks like PII or a credential; not saving',file=sys.stderr)
        sys.exit(4)
    bundle={'actor':a.actor,'test_id':a.test,'claim_type':'SIMULATED_ONLY','generated_at_utc':datetime.now(timezone.utc).isoformat(),'output':data}
    dest=ROOT/'evidence'/'simulations';dest.mkdir(parents=True,exist_ok=True)
    outfile=dest/f'{a.test}-{a.actor}.json'
    if outfile.exists():
        print('BLOCKED: simulation output exists; no overwrite',file=sys.stderr)
        sys.exit(5)
    outfile.write_text(json.dumps(bundle,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('SIMULATED_ONLY output:',outfile,'sha256:',hashlib.sha256(outfile.read_bytes()).hexdigest())

if __name__=='__main__':
    main()
