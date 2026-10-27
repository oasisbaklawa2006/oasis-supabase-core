#!/usr/bin/env python3
"""Offline hash-linked, PII-guarded UAT evidence recorder. No network or provider writes."""
import argparse
import csv
import datetime as dt
import hashlib
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

BASE = Path(__file__).resolve().parent
ROOT = BASE / 'evidence' / 'runs'
CASES = {r['test_id']: r for r in csv.DictReader((BASE / 'TEST_MATRIX.csv').open(encoding='utf-8'))}
STATUSES = {'NOT_RUN', 'BLOCKED', 'PASS', 'FAIL', 'INCONCLUSIVE'}
EVIDENCE = {'SIMULATED', 'PROVIDER_SIGNED', 'APP_VISIBLE', 'DB_READONLY', 'CI', 'HUMAN_ATTESTED', 'PROVIDER_DASHBOARD', 'HTTP_NEGATIVE'}
FIELDS = {'test_id', 'stage', 'actor', 'action', 'expected', 'observed', 'status', 'evidence_class', 'evidence_ref', 'pii_redacted'}
SENSITIVE_KEYS = {'password', 'otp', 'secret', 'access_token', 'api_key', 'bearer', 'authorization', 'phone', 'email', 'totp', 'cookie', 'private_key', 'session_token', 'jwt', 'auth_header', 'recovery_code'}
CREDENTIAL_PATTERNS = [
    re.compile(r'(?i)\bBearer\s+[A-Za-z0-9_\-\.]{15,}'),
    re.compile(r'(?i)\b(?:password|api[_-]?key|token|otp|secret|authorization)\s*[:=]\s*[\'"]?[^\s,;]{5,}'),
    re.compile(r'\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b'),
    re.compile(r'(?<![\w])\+?[1-9]\d{9,14}(?![\w])'),
    re.compile(r'\beyJ[A-Za-z0-9_-]{25,}\.eyJ[A-Za-z0-9_-]{25,}'),
]

def canonical(item):
    return json.dumps(item, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')

def run_path(run_id):
    if not re.fullmatch(r'WA450-[0-9]{8}-[A-Z0-9-]{2,24}', run_id):
        raise ValueError('run_id must be WA450-YYYYMMDD-ID, uppercase alphanumeric/hyphen')
    return ROOT / run_id

def no_secrets(value, path='$'):
    if isinstance(value, dict):
        for k, v in value.items():
            if k.lower() in SENSITIVE_KEYS or any(k.lower().endswith('_' + s) for s in SENSITIVE_KEYS):
                raise ValueError(f'sensitive key is not allowed: {path}.{k}')
            no_secrets(v, path + '.' + k)
    elif isinstance(value, list):
        for i, v in enumerate(value):
            no_secrets(v, f'{path}[{i}]')
    elif isinstance(value, str):
        if path.endswith('.evidence_ref') and re.fullmatch(
            r'https://github\.com/oasisbaklawa2006/oasis-supabase-core/(?:actions/runs|issues)/[0-9]+(?:#issuecomment-[0-9]+)?', value
        ):
            return
        for pattern in CREDENTIAL_PATTERNS:
            if pattern.search(value):
                raise ValueError(f'possible credential or PII at {path}; replace with pseudonym/hash')

def validate_event(item):
    if not isinstance(item, dict) or not FIELDS <= set(item):
        raise ValueError('event missing fields: ' + ', '.join(sorted(FIELDS - set(item))))
    if item['test_id'] not in CASES:
        raise ValueError('unknown test_id; see TEST_MATRIX.csv')
    if item['status'] not in STATUSES or item['evidence_class'] not in EVIDENCE:
        raise ValueError('invalid status or evidence_class')
    if item['pii_redacted'] is not True:
        raise ValueError('pii_redacted must be true')
    if item['status'] == 'PASS' and (item['evidence_class'] == 'SIMULATED' or item['evidence_ref'] in ('', 'evidence:none', None)):
        raise ValueError('PASS must have non-simulated evidence and concrete evidence_ref')
    if item['evidence_class'] in ('PROVIDER_SIGNED', 'PROVIDER_DASHBOARD') and not item.get('artifact_sha256'):
        raise ValueError('real provider proof requires evidence artifact sha256')
    if item['status'] == 'PASS' and item['test_id'].startswith(('WA-2', 'WA-3')) and item['evidence_class'] == 'CI':
        raise ValueError('live provider/operational PASS cannot be CI-only')
    no_secrets(item)

def read_entries(path):
    entries = []
    prev = '0' * 64
    if not path.exists():
        return entries
    with path.open(encoding='utf-8') as f:
        for n, line in enumerate(f, 1):
            o = json.loads(line)
            given = o.get('record_sha256')
            payload = {k: v for k, v in o.items() if k != 'record_sha256'}
            assert payload.get('seq') == n, f'wrong sequence at line {n}'
            assert payload.get('previous_sha256') == prev, f'bad chain at line {n}'
            actual = hashlib.sha256(canonical(payload)).hexdigest()
            assert actual == given, f'tamper detected at line {n}'
            prev = given
            entries.append(o)
    return entries

def initialize(args):
    out = run_path(args.run_id)
    if out.exists():
        raise ValueError('run exists; refusing to overwrite')
    out.mkdir(parents=True)
    (out / 'ledger.jsonl').touch(mode=0o600)
    meta = {'run_id': args.run_id, 'created_at_utc': now(), 'module': 'WA450', 'mode': 'OBSERVE', 'provider_live_approved': False, 'test_calls_sent': 0}
    (out / 'run_metadata.json').write_text(json.dumps(meta, indent=2) + '\n', encoding='utf-8')
    print('initialized', out)

def record(args):
    p = run_path(args.run_id) / 'ledger.jsonl'
    if not p.exists():
        raise ValueError('first initialize run')
    entries = read_entries(p)
    item = json.loads(Path(args.event).read_text(encoding='utf-8'))
    validate_event(item)
    body = {'seq': len(entries) + 1, 'previous_sha256': entries[-1]['record_sha256'] if entries else '0' * 64, 'recorded_at_utc': now(), 'event': item}
    body['record_sha256'] = hashlib.sha256(canonical(body)).hexdigest()
    with p.open('a', encoding='utf-8') as f:
        f.write(json.dumps(body, ensure_ascii=False, sort_keys=True) + '\n')
        f.flush()
    print('recorded seq', body['seq'], 'sha256', body['record_sha256'])

def verify(args):
    entries = read_entries(run_path(args.run_id) / 'ledger.jsonl')
    for item in entries:
        validate_event(item['event'])
    print(json.dumps({'run_id': args.run_id, 'entries': len(entries), 'hash_chain': 'PASS', 'last_record_sha256': entries[-1]['record_sha256'] if entries else None}, indent=2))

def report(args):
    events = read_entries(run_path(args.run_id) / 'ledger.jsonl')
    latest = {entry['event']['test_id']: entry['event'] for entry in events}
    case_rows = []
    for test_id, spec in sorted(CASES.items()):
        last = latest.get(test_id)
        case_rows.append({'id': test_id, 'mandatory': spec['mandatory'], 'status': last['status'] if last else 'NOT_RUN', 'evidence_class': last['evidence_class'] if last else 'NONE', 'evidence_ref': last['evidence_ref'] if last else 'NONE'})
    mandatory = [x for x in case_rows if x['mandatory'] == 'YES']
    result = {'run_id': args.run_id, 'record_count': len(events), 'verified_hash_chain': True,
              'mandatory_cases': len(mandatory), 'mandatory_pass': sum(x['status'] == 'PASS' for x in mandatory),
              'mandatory_fail': sum(x['status'] == 'FAIL' for x in mandatory),
              'mandatory_blocked_or_not_run': sum(x['status'] in ('BLOCKED','NOT_RUN','INCONCLUSIVE') for x in mandatory),
              'technical_candidate': all(x['status'] == 'PASS' for x in mandatory),
              'whole_module_certification': 'REQUIRES_INDEPENDENT_HUMAN_SIGNOFF_AND_LIVE_PROVIDER_PROOF',
              'cases': case_rows}
    dst = run_path(args.run_id) / 'report.json'
    dst.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: v for k,v in result.items() if k != 'cases'}, indent=2))
    print('details at', dst)

def checklist(_args):
    for x in CASES.values():
        print(f"{x['test_id']:6} {x['gate']:15} {x['actor']:18} {'REQUIRED' if x['mandatory']=='YES' else 'OPTIONAL':8} {x['scenario']}")

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    subs = ap.add_subparsers(dest='command', required=True)
    for command, func in [('init', initialize), ('record', record), ('verify', verify), ('report', report), ('checklist', checklist)]:
        p = subs.add_parser(command)
        if command != 'checklist': p.add_argument('--run-id', required=True)
        if command == 'record': p.add_argument('--event', required=True)
        p.set_defaults(func=func)
    args = ap.parse_args()
    try:
        args.func(args)
    except (ValueError, AssertionError, OSError, json.JSONDecodeError) as exc:
        print('BLOCKED:', exc, file=sys.stderr)
        sys.exit(2)

if __name__ == '__main__':
    main()
