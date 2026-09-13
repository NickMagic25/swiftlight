#!/usr/bin/env python3
from pathlib import Path
from collections import Counter
import json
root = Path(__file__).resolve().parents[1]
rows = []
for line in (root / 'docs/acceptance-matrix.md').read_text().splitlines():
    cells = [part.strip() for part in line.split('|')[1:-1]]
    if len(cells) != 7 or cells[5] not in {'PASS','FAIL','SKIP','BLOCKED','TODO'}: continue
    rows.append(dict(zip(['id','classification','implementation','automated','manual','status','evidence'], cells)))
for row in rows:
    row['requirement'] = row['id']
    row['id'] = row['id'].split()[0]
counts = Counter(row['status'] for row in rows)
result = {'counts': {key: counts[key] for key in ['PASS','FAIL','SKIP','BLOCKED','TODO']}, 'requirements': rows,
          'nonPassMacOSReleaseBlockers': [row['id'] for row in rows if row['classification'] == 'Release-blocking' and row['status'] != 'PASS']}
(root / 'artifacts').mkdir(exist_ok=True)
(root / 'artifacts/acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result['counts'], sort_keys=True))
print('Non-PASS macOS release gates:', ', '.join(result['nonPassMacOSReleaseBlockers']))
