#!/usr/bin/env python3
"""Offline validation for the JSON Schema vocabulary used by these fixtures."""
import json
from pathlib import Path
import re
import uuid
from datetime import datetime
from organiser_receiver import validate, canonical, digest

ROOT = Path(__file__).resolve().parent.parent / 'integration'

def check(value, schema):
    if 'const' in schema:
        assert value == schema['const'] and type(value) is type(schema['const'])
    if 'enum' in schema:
        assert value in schema['enum']
    kind = schema.get('type')
    if kind == 'object':
        assert isinstance(value, dict)
        assert set(schema.get('required', ())) <= value.keys()
        if schema.get('additionalProperties') is False:
            assert value.keys() <= schema['properties'].keys()
        for key, item in value.items():
            check(item, schema['properties'][key])
    elif kind == 'array':
        assert isinstance(value, list) and len(value) <= schema.get('maxItems', float('inf'))
        if schema.get('uniqueItems'):
            assert len({canonical(item) for item in value}) == len(value)
        for item in value:
            check(item, schema['items'])
    elif kind == 'integer':
        assert type(value) is int
        assert schema.get('minimum', -float('inf')) <= value <= schema.get('maximum', float('inf'))
    elif kind == 'string':
        assert isinstance(value, str)
        assert schema.get('minLength', 0) <= len(value) <= schema.get('maxLength', float('inf'))
        if 'pattern' in schema:
            assert re.search(schema['pattern'], value)
        if schema.get('format') == 'uuid':
            uuid.UUID(value)
        if schema.get('format') == 'date-time':
            assert datetime.fromisoformat(value.replace('Z', '+00:00')).tzinfo is not None

if __name__ == '__main__':
    for name in ('request', 'receipt', 'error', 'capabilities'):
        schema = json.loads((ROOT / f'{name}-v1.schema.json').read_text())
        fixture = json.loads((ROOT / 'fixtures' / f'{name}-v1.json').read_text())
        check(fixture, schema)
    request = json.loads((ROOT/'fixtures/request-v1.json').read_text())
    validate(request, request['payload']['workspace_id'])
    assert digest(canonical(request['payload'])) == (ROOT/'fixtures/payload-v1.sha256').read_text().strip()
    print('Four schema fixtures and canonical digest validated.')
