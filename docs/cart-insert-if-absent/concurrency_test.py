import subprocess, json, concurrent.futures as cf, sys
import os
DB=os.environ.get('DB','core_r6')
def q(sql, uid=None, check=False):
    pre = f"select set_config('request.jwt.claim.sub','{uid}',false);" if uid else ""
    r = subprocess.run(['su','postgres','-c',f"psql -h /tmp -p 54329 -d {DB} -At -F '|' -v ON_ERROR_STOP=1 -c \"{pre}{sql}\""],capture_output=True,text=True)
    out=[l for l in r.stdout.strip().splitlines() if l and not (uid and len(l)==36 or l.startswith('{') ) ] if False else r.stdout.strip().splitlines()
    return r.returncode, out, r.stderr.strip()
A1='a1a1a1a1-0000-0000-0000-000000000001'; A2='a1a1a1a1-0000-0000-0000-000000000002'; B1='b1b1b1b1-0000-0000-0000-000000000001'; ST='c1c1c1c1-0000-0000-0000-000000000001'
P1='11111111-0000-0000-0000-000000000001'; P2='11111111-0000-0000-0000-000000000002'
res=[]
def ok(name,cond,detail=''): res.append((name,bool(cond),detail)); print(('ok   ' if cond else 'FAIL ')+name, detail if not cond else '')
def ifabs(uid,p,qty):
    rc,out,err=q(f"select inserted, existing_quantity, line_id from public.add_customer_order_draft_line_if_absent_v1('{p}',{qty})",uid)
    return rc,(out[-1] if out else ''),err
def qty(uid_co,p):
    rc,out,_=q(f"select quantity from public.customer_order_draft_lines l join public.customer_order_drafts d on d.id=l.draft_id where d.company_id='{uid_co}' and d.status='active' and l.product_id='{p}'")
    return out[-1] if out else None
CA='aaaaaaaa-0000-0000-0000-00000000000a'; CB='bbbbbbbb-0000-0000-0000-00000000000b'
# 1 first insert
rc,o,e=ifabs(A1,P1,9); ok('1 first call inserts', rc==0 and o.startswith('t|9'),o+e)
line1=o.split('|')[2] if rc==0 else None
# 2 retry is idempotent: no overwrite, same line id
rc,o,e=ifabs(A1,P1,18); ok('2 retry with a different quantity does not overwrite', rc==0 and o.startswith('f|9') and o.endswith(line1), o+e)
ok('2b stored quantity still 9', qty(CA,P1)=='9.0000' or qty(CA,P1) in ('9','9.0','9.00'), qty(CA,P1))
# 3 stale read: A reads cart (P2 absent), B-session (same company, other user) adds 27 with the OLD upsert, A then writes MOQ
q(f"select * from public.add_customer_order_draft_line_v1('{P2}',27)",A2)
rc,o,e=ifabs(A1,P2,9); ok('3 stale-read: newer quantity 27 survives', rc==0 and o.startswith('f|27'), o+e)
ok('3b stored quantity 27', qty(CA,P2).startswith('27'), qty(CA,P2))
# 3c demonstrate the defect in the OLD upsert path
q(f"select * from public.add_customer_order_draft_line_v1('{P2}',9)",A1)
ok('3c (baseline defect) old upsert overwrote 27 -> 9', qty(CA,P2).startswith('9'), qty(CA,P2))
# cleanup A cart
q("select * from public.clear_customer_order_draft_v1()",A1)
ok('cart cleared', qty(CA,P1) is None)
# 4 true concurrency: 24 parallel callers (two users of one company), distinct valid quantities, same product
qs=[9*(i+1) for i in range(24)]
def go(i): return ifabs(A1 if i%2==0 else A2,P1,qs[i])
with cf.ThreadPoolExecutor(24) as ex: outs=list(ex.map(go,range(24)))
ins=[o for rc,o,e in outs if rc==0 and o.startswith('t|')]; notins=[o for rc,o,e in outs if rc==0 and o.startswith('f|')]; errs=[(o,e) for rc,o,e in outs if rc!=0]
ok('4 concurrency: exactly one insert, 23 report existing, 0 errors', len(ins)==1 and len(notins)==23 and not errs, str((len(ins),len(notins),errs[:2])))
win=ins[0].split('|')[1] if ins else None
ok('4b final quantity equals the single winner', qty(CA,P1)==win or (qty(CA,P1) and float(qty(CA,P1))==float(win)), f"{qty(CA,P1)} vs {win}")
ok('4c every loser reported the winner quantity', all(float(o.split('|')[1])==float(win) for o in notins), '')
rc,out,_=q(f"select count(*) from public.customer_order_draft_lines l join public.customer_order_drafts d on d.id=l.draft_id where d.company_id='{CA}' and l.product_id='{P1}'"); ok('4d one line row', out[-1]=='1', out)
rc,out,_=q(f"select count(*) from public.customer_order_drafts where company_id='{CA}' and status='active'"); ok('4e one active draft', out[-1]=='1', out)
# 4f audit: one if_absent ADD_LINE for this product in company A during run
rc,out,_=q(f"select count(*) from public.customer_order_draft_audit_log where company_id='{CA}' and action='ADD_LINE' and detail->>'mode'='if_absent' and detail->>'product_id'='{P1}'"); ok('4f audit rows: 2 inserts total for P1 (step1 + concurrency winner)', out[-1]=='2', out)
# 5 tenant isolation
before=qty(CA,P1)
rc,o,e=ifabs(B1,P1,9); ok('5 other tenant inserts its own line', rc==0 and o.startswith('t|9'), o+e)
ok('5b tenant A quantity untouched', qty(CA,P1)==before)
rc,out,_=q(f"select count(*) from public.customer_order_drafts d join public.customer_order_draft_lines l on l.draft_id=d.id where d.company_id='{CB}'"); ok('5c tenant B has exactly its own line', out[-1]=='1', out)
# 6 gates
rc,o,e=ifabs(None,P1,9); ok('6 unauthenticated rejected', rc!=0 and 'AUTH_REQUIRED' in e, e)
rc,o,e=ifabs(ST,P1,9); ok('6b non-buyer rejected', rc!=0 and 'BUYER_NOT_ELIGIBLE' in e, e)
rc,o,e=ifabs(A1,P2,10); ok('6c MOQ/increment violation rejected', rc!=0 and 'QUANTITY_RULE_VIOLATION' in e, e)
rc,o,e=ifabs(A1,'99999999-0000-0000-0000-000000000009',9); ok('6d unknown product rejected', rc!=0 and 'PRODUCT_UNAVAILABLE' in e, e)
rc,o,e=ifabs(A1,P2,0); ok('6e zero quantity rejected', rc!=0 and 'VALIDATION_FAILED' in e, e)
rc,out,_=q("select has_function_privilege('anon','public.add_customer_order_draft_line_if_absent_v1(uuid,numeric)','EXECUTE'), has_function_privilege('authenticated','public.add_customer_order_draft_line_if_absent_v1(uuid,numeric)','EXECUTE')"); ok('6f anon no EXECUTE, authenticated EXECUTE', out[-1]=='f|t', out)
rc,out,_=q(f"select count(*) from public.customer_order_drafts where company_id='{CA}' and status='active' and exists(select 1 from public.customer_order_draft_lines l where l.draft_id=id and l.product_id='{P2}')"); ok('6g rejected calls left no stray line', out[-1]=='0', out)
json.dump([{'test':n,'pass':p,'detail':d} for n,p,d in res],open('/var/tmp/p100r6/results.json','w'),indent=1)
print(f"\n{sum(p for _,p,_ in res)}/{len(res)} passed")
sys.exit(0 if all(p for _,p,_ in res) else 1)
