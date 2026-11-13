#!/usr/bin/env python3
"""Loopback-only, credential-free E2E APIs. Invalid real-world payloads fail loudly."""
import argparse, http.server, json, pathlib, socket, time, urllib.parse, uuid

state = {}
def reset():
    state.clear()
    state.update(down=False, limited=set(), pages={}, metrics=dict(jev=0, pages=0, sheets=0, appends=0, rateLimits=0, requests=0))
reset()

def units(text): return len(text.encode('utf-16-le')) // 2

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, body, headers=None):
        data = json.dumps(body, sort_keys=True).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        for key, value in (headers or {}).items(): self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self): self.handle_api()
    def do_PATCH(self): self.handle_api()
    def do_POST(self): self.handle_api()
    def handle_api(self):
        path = urllib.parse.urlparse(self.path).path
        length = int(self.headers.get('Content-Length', '0'))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw) if raw else {}
            if path.startswith('/control/'):
                command = path.split('/')[-1]
                if command == 'reset': reset()
                if command == 'down': state['down'] = True
                if command == 'up': state['down'] = False
                if command == 'rate-limit': state['limited'] = {'notion', 'sheets'}
                return self.reply(200, state['metrics'] if command == 'metrics' else {})
            if path == '/v1/systemone':
                state['metrics']['jev'] += 1
                assert body['model'] == 'jev-latest'
                assert body['questions']['changed']['type'] == 'noul'
                assert set(body['state']['current']) == {'app', 'title', 'text'}
                return self.reply(200, {'answers': {'changed': {'noul': 0 if body['state']['previous'] == body['state']['current'] else 1}}})
            if state['down']:
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            state['metrics']['requests'] += 1
            destination = 'sheets' if path.startswith('/v4/') else 'notion'
            if destination in state['limited']:
                state['limited'].remove(destination)
                state['metrics']['rateLimits'] += 1
                return self.reply(429, {'error': 'rate_limited'}, {'Retry-After': '60'})
            assert self.headers.get('Authorization') == 'Bearer e2e-placeholder'
            if destination == 'notion': assert self.headers.get('Notion-Version') == '2026-03-11'
            if path.startswith('/v1/databases/'):
                return self.reply(200, {'data_sources': [{'id': '00000000-0000-0000-0000-000000000002'}]})
            if path.startswith('/v1/data_sources/'):
                return self.reply(200, {'properties': {k: {'type': v} for k, v in [('Name','title'),('Timestamp','date'),('App','rich_text'),('Dwell','number')]}})
            if path == '/v1/pages' or path.endswith('/children'):
                assert length < 500_000, 'Notion payload > 500KB'
                children = body['children']
                assert len(children) <= 100, 'Notion children > 100'
                for child in children:
                    assert child['type'] == 'paragraph'
                    for text in child['paragraph']['rich_text']: assert units(text['text']['content']) <= 2000
                if path == '/v1/pages':
                    assert body['parent'] == {'type':'data_source_id', 'data_source_id':'00000000-0000-0000-0000-000000000002'}
                    assert set(body['properties']) == {'Name','Timestamp','App','Dwell'}
                    state['metrics']['pages'] += 1
                    page = str(uuid.uuid4()); state['pages'][page] = children
                    return self.reply(200, {'id': page})
                page = path.split('/')[3]
                assert page in state['pages'], 'unknown page'
                state['pages'][page].extend(children); state['metrics']['appends'] += 1
                return self.reply(200, {'results': []})
            if path.startswith('/v4/spreadsheets/'):
                assert urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)['valueInputOption'] == ['RAW']
                assert body['majorDimension'] == 'ROWS' and len(body['values']) == 1
                assert len(body['values'][0]) == 5
                for value in body['values'][0]:
                    if isinstance(value, str): assert units(value) <= 49000
                state['metrics']['sheets'] += 1
                return self.reply(200, {'updates': {'updatedRows': 1}})
            self.reply(404, {})
        except (AssertionError, KeyError, TypeError, ValueError) as error:
            # Assertions contain no request body, credentials or user text.
            print('MOCK CONTRACT FAILURE:', type(error).__name__, str(error), flush=True)
            self.reply(400, {'error': 'contract_violation'})

parser = argparse.ArgumentParser(); parser.add_argument('--port-file', required=True)
args = parser.parse_args()
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(args.port_file).write_text(str(server.server_port))
server.serve_forever()
