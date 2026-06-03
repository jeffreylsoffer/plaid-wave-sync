# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx"]
# ///
"""Match Plaid accounts to Wave accounts by mask (type-aware).

Emits, for setup.sh to consume:
  /tmp/plaid-access-tokens.json — JSON array of matched entries [{name, token, wave_account, type, account_id}]
  /tmp/plaid-unmatched.jsonl    — one {name,token,type,mask,account_id} per unmatched account
  /tmp/wave-account-options.txt — one "wave_name|category" per line (category: asset|liability)
"""
import json, os, sys, httpx

with open('/tmp/plaid-tokens-all.jsonl') as f:
    tokens = [json.loads(l) for l in f if l.strip()]

biz_id = os.environ.get('WAVE_BUSINESS_ID', '')
wave_token = os.environ.get('WAVE_ACCESS_TOKEN', '')
if not wave_token or not biz_id:
    print(f"  ✗ Missing env vars: WAVE_ACCESS_TOKEN={'set' if wave_token else 'EMPTY'}, WAVE_BUSINESS_ID={'set' if biz_id else 'EMPTY'}")
    sys.exit(1)

# System accounts that aren't real bank/CC accounts
SYSTEM_ACCOUNTS = {
    'accounts payable', 'accounts receivable', 'transfer clearing',
    'cash on hand', 'payroll liabilities', 'taxes payable',
    'taxes recoverable/refundable', 'employee 401k contributions',
    'shareholder loan',
}

# wave_accounts: list of (name, category) where category in {'asset','liability'}
wave_accounts, page = [], 1
while True:
    r = httpx.post('https://gql.waveapps.com/graphql/public',
        headers={'Authorization': f'Bearer {wave_token}'},
        json={'query': 'query($id:ID!,$p:Int!){business(id:$id){accounts(page:$p,pageSize:50){pageInfo{totalPages}edges{node{name type{name} isArchived}}}}}',
              'variables': {'id': biz_id, 'p': page}}, timeout=30)
    resp = r.json()
    if 'errors' in resp or 'data' not in resp:
        print(f"  ✗ Wave API error: {resp.get('errors', resp)}")
        sys.exit(1)
    d = resp['data']['business']['accounts']
    for e in d['edges']:
        n = e['node']
        if n['isArchived']:
            continue
        cat = {'Assets': 'asset', 'Liabilities & Credit Cards': 'liability'}.get(n['type']['name'])
        if not cat or n['name'].lower() in SYSTEM_ACCOUNTS:
            continue
        if (n['name'], cat) not in wave_accounts:
            wave_accounts.append((n['name'], cat))
    if page >= d['pageInfo']['totalPages']:
        break
    page += 1


def compatible(acct_type):
    return 'liability' if acct_type == 'credit_card' else 'asset'


matched, unmatched = [], []
for t in tokens:
    token = t.get('access_token', '')
    for acct in t['accounts']:
        name = acct.get('name', 'Bank')
        mask = str(acct.get('mask') or '')
        acct_type = acct.get('type', 'checking')
        account_id = acct.get('account_id', '')
        cands = [w for w, c in wave_accounts if c == compatible(acct_type)]
        hit = next((w for w in cands if mask and mask != '0000' and mask in w), None)
        if not hit and len(mask) >= 3:  # banks/Wave sometimes record only the last 3 digits
            hit = next((w for w in cands if mask[-3:] in w), None)
        if hit:
            matched.append({"name": name, "token": token, "wave_account": hit,
                            "type": acct_type, "account_id": account_id})
            print(f"  ✓ {name} (mask={mask}) → {hit} ({acct_type})")
        else:
            unmatched.append({"name": name, "token": token, "type": acct_type,
                              "mask": mask, "account_id": account_id})
            print(f"  ⚠ {name} (mask={mask}) — needs manual pick ({acct_type})")

with open('/tmp/plaid-access-tokens.json', 'w') as f:
    json.dump(matched, f)
with open('/tmp/plaid-unmatched.jsonl', 'w') as f:
    for u in unmatched:
        f.write(json.dumps(u) + '\n')
with open('/tmp/wave-account-options.txt', 'w') as f:
    for w, c in wave_accounts:
        f.write(f"{w}|{c}\n")
