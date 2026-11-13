#!/usr/bin/env python3
import json, pathlib, re
root=pathlib.Path(__file__).resolve().parents[1]
catalog=json.loads((root/'Sources/WYSIWAGApp/Resources/Localizable.xcstrings').read_text())
entries=catalog['strings']
required=set()
for file in (root/'Sources/WYSIWAGApp').glob('*.swift'):
    text=file.read_text()
    required.update(re.findall(r'(?:\bt|\.tr)\("([^"\\]*)"\)', text))
for key in required:
    assert key in entries, f'Missing String Catalog entry: {key}'
for key,entry in entries.items():
    for lang in ['en','ja']:
        value=entry['localizations'][lang]['stringUnit']
        assert value['state']=='translated' and value['value'], (key,lang)
assert catalog['sourceLanguage']=='en'
print(f'PASS: {len(entries)} UI strings translated in en + ja')
