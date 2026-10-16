"""Single-owner organiser. PostgreSQL commits are the acknowledgement boundary."""
import base64
import hashlib
import hmac
import json
import os
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Literal
from uuid import UUID

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, ConfigDict, Field, model_validator


class Attachment(BaseModel):
    model_config = ConfigDict(extra='forbid')
    path: str = Field(min_length=1, max_length=4096)
    media_type: Literal['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'application/octet-stream']
    data_base64: str = Field(max_length=24 * 1024 * 1024)

    @model_validator(mode='after')
    def safe_file(self):
        if self.path.startswith('/') or '\\' in self.path or any(p in ('', '.', '..') for p in self.path.split('/')):
            raise ValueError('Unsafe attachment path')
        try:
            base64.b64decode(self.data_base64, validate=True)
        except ValueError:
            raise ValueError('Invalid attachment encoding')
        return self


class Item(BaseModel):
    model_config = ConfigDict(extra='forbid')
    body_markdown: str = Field(max_length=1024 * 1024)
    kind: Literal['capture', 'task', 'note', 'bookmark', 'event', 'reminder', 'project'] = 'capture'
    section: str = Field(default='Quick capture', max_length=256)
    completed: bool = False
    deleted: bool = False
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    reminder_at: datetime | None = None
    source_url: str | None = Field(default=None, max_length=8192)

    @model_validator(mode='after')
    def dates(self):
        for value in (self.starts_at, self.ends_at, self.reminder_at):
            if value and value.utcoffset() is None:
                raise ValueError('Dates must include a timezone')
        if self.ends_at and (not self.starts_at or self.ends_at < self.starts_at):
            raise ValueError('Event end must follow its start')
        if self.kind == 'event' and not self.starts_at:
            raise ValueError('An event requires a start time')
        if self.source_url and not self.source_url.startswith(('https://', 'http://')):
            raise ValueError('Bookmark URL must use HTTP or HTTPS')
        return self


class Mutation(BaseModel):
    model_config = ConfigDict(extra='forbid')
    operation_id: UUID
    item_id: UUID
    expected_revision: int = Field(ge=0)
    item: Item
    # None retains attachments; [] explicitly removes them.
    attachments: list[Attachment] | None = Field(default=None, max_length=16)

    @model_validator(mode='after')
    def unique_files(self):
        if self.item.kind == 'project' and self.attachments != []:
            raise ValueError('Project sync stores inbox.md only; attachments must be an empty list')
        paths = [a.path for a in self.attachments or []]
        if len(paths) != len(set(paths)):
            raise ValueError('Duplicate attachment path')
        return self


SCHEMA = '''
CREATE TABLE IF NOT EXISTS organiser_schema (version integer PRIMARY KEY);
INSERT INTO organiser_schema SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM organiser_schema);
CREATE TABLE IF NOT EXISTS items (
    id uuid PRIMARY KEY, revision bigint NOT NULL, document jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS operations (
    id uuid PRIMARY KEY, digest text NOT NULL, receipt jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS attachments (
    item_id uuid NOT NULL REFERENCES items(id), path text NOT NULL,
    media_type text NOT NULL, content bytea NOT NULL,
    PRIMARY KEY(item_id, path)
);
'''


def create_app(database_url=None, token=None):
    database_url = database_url or os.environ['DATABASE_URL']
    if token is None:
        token_file = os.environ.get('ORGANISER_TOKEN_FILE')
        token = Path(token_file).read_text().strip() if token_file else os.environ.get('ORGANISER_TOKEN', '')
    if len(token) < 32:
        raise RuntimeError('A private token of at least 32 characters is required')
    pool = ConnectionPool(database_url, open=False, min_size=1, max_size=5,
                          kwargs={'row_factory': dict_row})

    @asynccontextmanager
    async def lifespan(app):
        pool.open(wait=True)
        with pool.connection() as conn:
            conn.execute('SELECT pg_advisory_xact_lock(735021)')
            conn.execute(SCHEMA)
            versions = conn.execute('SELECT version FROM organiser_schema').fetchall()
            if [row['version'] for row in versions] == [1]:
                # The mutation lock keeps sequence allocation in commit order,
                # including the initial backfill of existing identities.
                conn.execute('SELECT pg_advisory_xact_lock(735022)')
                conn.execute("""CREATE TABLE item_changes (
                    sequence bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
                    item_id uuid NOT NULL UNIQUE REFERENCES items(id),
                    revision bigint NOT NULL
                )""")
                conn.execute('INSERT INTO item_changes(item_id, revision) SELECT id, revision FROM items ORDER BY created_at, id')
                conn.execute('UPDATE organiser_schema SET version=2 WHERE version=1')
                versions = [{'version': 2}]
            if [row['version'] for row in versions] != [2]:
                raise RuntimeError('Unsupported database schema; refusing to start')
        yield
        pool.close()

    app = FastAPI(title='Home organiser', lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    bearer = HTTPBearer(auto_error=False)

    def authorised(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        if not credentials or not hmac.compare_digest(credentials.credentials.encode(), token.encode()):
            raise HTTPException(401, 'Authentication required', headers={'WWW-Authenticate': 'Bearer'})

    @app.middleware('http')
    async def limits(request: Request, call_next):
        # Bound streamed bodies as well as Content-Length before JSON parsing.
        if request.method in ('POST', 'PUT', 'PATCH'):
            size = 0
            chunks = []
            async for chunk in request.stream():
                size += len(chunk)
                if size > 26 * 1024 * 1024:
                    return Response(status_code=413)
                chunks.append(chunk)
            request._body = b''.join(chunks)
        response = await call_next(request)
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        return response

    @app.get('/health')
    def health():
        with pool.connection() as conn:
            conn.execute('SELECT 1')
        return {'status': 'ok'}

    @app.get('/api/changes', dependencies=[Depends(authorised)])
    def changes(after: int = 0, limit: int = 100):
        if after < 0 or not 1 <= limit <= 1000:
            raise HTTPException(422, 'Invalid change cursor or limit')
        with pool.connection() as conn:
            rows = conn.execute('SELECT sequence, item_id, revision FROM item_changes WHERE sequence > %s ORDER BY sequence LIMIT %s', (after, limit)).fetchall()
        return {'changes': rows, 'cursor': rows[-1]['sequence'] if rows else after}

    @app.get('/api/items', dependencies=[Depends(authorised)])
    def items(include_deleted: bool = False, offset: int = 0, limit: int = 200):
        if offset < 0 or not 1 <= limit <= 1000:
            raise HTTPException(422, 'Invalid page')
        with pool.connection() as conn:
            rows = conn.execute("SELECT id, revision, document, created_at, updated_at FROM items WHERE %s OR NOT (document->>'deleted')::boolean ORDER BY created_at, id LIMIT %s OFFSET %s", (include_deleted, limit, offset)).fetchall()
        return rows

    @app.get('/api/items/{item_id}', dependencies=[Depends(authorised)])
    def item(item_id: UUID):
        with pool.connection() as conn:
            row = conn.execute('SELECT * FROM items WHERE id=%s', (item_id,)).fetchone()
            if not row:
                raise HTTPException(404, 'Item not found')
            row['attachments'] = conn.execute('SELECT path, media_type, octet_length(content) AS byte_count FROM attachments WHERE item_id=%s ORDER BY path', (item_id,)).fetchall()
            return row

    @app.get('/api/items/{item_id}/attachment', dependencies=[Depends(authorised)])
    def attachment(item_id: UUID, path: str):
        with pool.connection() as conn:
            row = conn.execute('SELECT media_type, content FROM attachments WHERE item_id=%s AND path=%s', (item_id, path)).fetchone()
        if not row:
            raise HTTPException(404, 'Attachment not found')
        return Response(bytes(row['content']), media_type=row['media_type'], headers={'Content-Disposition': 'attachment'})

    @app.post('/api/operations', dependencies=[Depends(authorised)])
    def mutate(change: Mutation):
        canonical = json.dumps(change.model_dump(mode='json'), sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
        digest = hashlib.sha256(canonical).hexdigest()
        with pool.connection() as conn:
            # Single-owner workload: serialise writes to make retry and create races unambiguous.
            conn.execute('SELECT pg_advisory_xact_lock(735022)')
            old = conn.execute('SELECT digest, receipt FROM operations WHERE id=%s', (change.operation_id,)).fetchone()
            if old:
                if old['digest'] != digest:
                    raise HTTPException(409, {'code': 'operation_reused'})
                return old['receipt']
            current = conn.execute('SELECT * FROM items WHERE id=%s FOR UPDATE', (change.item_id,)).fetchone()
            revision = current['revision'] if current else 0
            if revision != change.expected_revision:
                # UUID/datetime are encoded by FastAPI only for regular return values.
                conflict = json.loads(json.dumps(current, default=str)) if current else None
                raise HTTPException(409, {'code': 'revision_conflict', 'current': conflict})
            if current and current['document']['deleted']:
                raise HTTPException(409, {'code': 'item_deleted'})
            if not current and change.item.deleted:
                raise HTTPException(422, 'Cannot delete an unknown item')
            document = change.item.model_dump(mode='json')
            revision += 1
            conn.execute('INSERT INTO items(id, revision, document) VALUES (%s,%s,%s) ON CONFLICT(id) DO UPDATE SET revision=EXCLUDED.revision, document=EXCLUDED.document, updated_at=now()', (change.item_id, revision, Jsonb(document)))
            if change.attachments is not None:
                conn.execute('DELETE FROM attachments WHERE item_id=%s', (change.item_id,))
                for file in change.attachments:
                    conn.execute('INSERT INTO attachments VALUES (%s,%s,%s,%s)', (change.item_id, file.path, file.media_type, base64.b64decode(file.data_base64)))
            conn.execute('INSERT INTO item_changes(item_id, revision) VALUES (%s,%s) ON CONFLICT(item_id) DO UPDATE SET sequence=EXCLUDED.sequence, revision=EXCLUDED.revision', (change.item_id, revision))
            receipt = {'operation_id': str(change.operation_id), 'item_id': str(change.item_id), 'revision': revision}
            conn.execute('INSERT INTO operations VALUES (%s,%s,%s)', (change.operation_id, digest, Jsonb(receipt)))
        return receipt

    static = Path(__file__).parent / 'static'
    @app.get('/')
    def index():
        return FileResponse(static / 'index.html')

    @app.get('/app.js')
    def javascript():
        return FileResponse(static / 'app.js', media_type='text/javascript')

    @app.get('/calendar.js')
    def calendar_javascript():
        return FileResponse(static / 'calendar.js', media_type='text/javascript')

    @app.get('/style.css')
    def stylesheet():
        return FileResponse(static / 'style.css', media_type='text/css')

    return app
