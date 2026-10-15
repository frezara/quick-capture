import base64
import os
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import psycopg
import pytest
from fastapi.testclient import TestClient
from organiser.app import create_app

TOKEN = 'test-only-token-that-is-at-least-32-characters'

@pytest.fixture
def client():
    url = os.environ['TEST_DATABASE_URL']
    with psycopg.connect(url) as conn:
        conn.execute('DROP TABLE IF EXISTS item_changes, attachments, operations, items, organiser_schema CASCADE')
    with TestClient(create_app(url, TOKEN)) as client:
        client.headers['Authorization'] = f'Bearer {TOKEN}'
        yield client


def operation(**changes):
    return {'operation_id': str(uuid4()), 'item_id': str(uuid4()), 'expected_revision': 0,
            'item': {'body_markdown': 'Remember this'}, **changes}


def test_auth_and_health(client):
    assert client.get('/health').status_code == 200
    assert client.get('/api/items', headers={'Authorization': ''}).status_code == 401
    assert client.get('/').status_code == 200


def test_create_retry_edit_conflict_and_delete(client):
    change = operation()
    receipt = client.post('/api/operations', json=change).json()
    assert receipt['revision'] == 1
    assert client.post('/api/operations', json=change).json() == receipt
    reused = {**change, 'item': {'body_markdown': 'Different'}}
    assert client.post('/api/operations', json=reused).json()['detail']['code'] == 'operation_reused'
    update = operation(item_id=change['item_id'], expected_revision=1, item={'body_markdown':'Edited', 'completed':True})
    assert client.post('/api/operations', json=update).json()['revision'] == 2
    stale = operation(item_id=change['item_id'], expected_revision=1)
    assert client.post('/api/operations', json=stale).json()['detail']['current']['document']['body_markdown'] == 'Edited'
    deleted = operation(item_id=change['item_id'], expected_revision=2, item={'body_markdown':'Edited', 'deleted':True})
    assert client.post('/api/operations', json=deleted).json()['revision'] == 3
    assert client.get('/api/items').json() == []
    assert len(client.get('/api/items?include_deleted=true').json()) == 1
    assert client.post('/api/operations', json=change).json() == receipt
    assert client.post('/api/operations', json=operation(item_id=change['item_id'], expected_revision=3)).json()['detail']['code'] == 'item_deleted'


def test_concurrent_create_and_update(client):
    change = operation()
    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(lambda _: client.post('/api/operations',json=change),range(2)))
    assert [r.status_code for r in results] == [200,200]
    assert results[0].json() == results[1].json()
    updates = [operation(item_id=change['item_id'], expected_revision=1, item={'body_markdown': text}) for text in ('One','Two')]
    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(lambda op:client.post('/api/operations',json=op),updates))
    assert sorted(r.status_code for r in results) == [200,409]


def test_attachments_committed_retained_and_replaced(client):
    change=operation(attachments=[{'path':'attachments/a.png','media_type':'image/png','data_base64':base64.b64encode(b'image bytes').decode()}])
    assert client.post('/api/operations',json=change).status_code == 200
    path=f"/api/items/{change['item_id']}"
    assert client.get(path+'/attachment?path=attachments/a.png').content == b'image bytes'
    assert client.post('/api/operations',json=operation(item_id=change['item_id'],expected_revision=1)).status_code == 200
    assert len(client.get(path).json()['attachments']) == 1
    assert client.post('/api/operations',json=operation(item_id=change['item_id'],expected_revision=2,attachments=[])).status_code == 200
    assert client.get(path).json()['attachments'] == []


@pytest.mark.parametrize('item',[
    {'body_markdown':'x','kind':'event'},
    {'body_markdown':'x','kind':'event','starts_at':'2026-10-15T10:00:00'},
    {'body_markdown':'x','source_url':'javascript:alert(1)'},
])
def test_invalid_documents(client,item):
    assert client.post('/api/operations',json=operation(item=item)).status_code == 422
    assert client.get('/api/items').json() == []


def test_invalid_attachment_does_not_create_record(client):
    change=operation(attachments=[{'path':'../a.png','media_type':'image/png','data_base64':'aGVsbG8='}])
    assert client.post('/api/operations',json=change).status_code == 422
    assert client.get('/api/items').json() == []


def test_receipt_survives_new_application_instance(client):
    change = operation()
    receipt = client.post('/api/operations', json=change).json()
    with TestClient(create_app(os.environ['TEST_DATABASE_URL'], TOKEN)) as restarted:
        restarted.headers['Authorization'] = f'Bearer {TOKEN}'
        assert restarted.post('/api/operations', json=change).json() == receipt
        assert restarted.get(f"/api/items/{change['item_id']}").json()['revision'] == 1


def test_database_failure_rolls_back_item_attachment_and_receipt(client):
    with psycopg.connect(os.environ['TEST_DATABASE_URL']) as conn:
        conn.execute("CREATE OR REPLACE FUNCTION reject_test_attachment() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test disk failure'; END $$")
        conn.execute('CREATE TRIGGER reject_attachment BEFORE INSERT ON attachments FOR EACH ROW EXECUTE FUNCTION reject_test_attachment()')
    change = operation(attachments=[{'path':'a.png','media_type':'image/png','data_base64':'aGVsbG8='}])
    with pytest.raises(psycopg.errors.RaiseException):
        client.post('/api/operations',json=change)
    assert client.get('/api/items').json() == []
    with psycopg.connect(os.environ['TEST_DATABASE_URL']) as conn:
        assert conn.execute('SELECT count(*) FROM operations').fetchone()[0] == 0
        assert conn.execute('SELECT count(*) FROM attachments').fetchone()[0] == 0
        conn.execute('DROP TRIGGER reject_attachment ON attachments')
    assert client.post('/api/operations',json=change).json()['revision'] == 1


def test_change_feed_pages_edits_retries_and_tombstones(client):
    first, second = operation(), operation()
    for op in (first, second):
        assert client.post('/api/operations', json=op).status_code == 200
    page = client.get('/api/changes?limit=1').json()
    assert [row['item_id'] for row in page['changes']] == [first['item_id']]
    cursor = page['cursor']
    edit = operation(item_id=first['item_id'], expected_revision=1, item={'body_markdown':'changed'})
    assert client.post('/api/operations', json=edit).status_code == 200
    next_page = client.get(f'/api/changes?after={cursor}').json()
    assert [row['item_id'] for row in next_page['changes']] == [second['item_id'], first['item_id']]
    assert next_page['changes'][-1]['revision'] == 2
    cursor = next_page['cursor']
    assert client.post('/api/operations', json=edit).status_code == 200
    assert client.get(f'/api/changes?after={cursor}').json() == {'changes': [], 'cursor': cursor}
    deletion = operation(item_id=second['item_id'], expected_revision=1, item={'body_markdown':'', 'deleted':True})
    assert client.post('/api/operations', json=deletion).status_code == 200
    assert client.get(f'/api/changes?after={cursor}').json()['changes'][0]['item_id'] == second['item_id']
    assert client.get('/api/changes?after=-1').status_code == 422
    assert client.get('/api/changes', headers={'Authorization':''}).status_code == 401


def test_change_feed_migrates_existing_database(client):
    op = operation()
    client.post('/api/operations', json=op)
    with psycopg.connect(os.environ['TEST_DATABASE_URL']) as conn:
        conn.execute('DROP TABLE item_changes')
        conn.execute('UPDATE organiser_schema SET version=1')
    with TestClient(create_app(os.environ['TEST_DATABASE_URL'], TOKEN)) as restarted:
        restarted.headers['Authorization'] = f'Bearer {TOKEN}'
        changes = restarted.get('/api/changes').json()['changes']
        assert len(changes) == 1
        assert changes[0]['item_id'] == op['item_id']
        assert changes[0]['revision'] == 1
