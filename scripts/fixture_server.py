#!/usr/bin/env python3
"""Local-only Micropub fixture. No real accounts, tokens or posts."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import json
from pathlib import Path
LOG=Path('/private/tmp/quill-fixture-requests.jsonl')
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def reply(self,data,status=200,headers=None):
        body=json.dumps(data).encode(); self.send_response(status)
        self.send_header('Content-Type','application/json')
        for key,value in (headers or {}).items(): self.send_header(key,value)
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        query=parse_qs(urlparse(self.path).query)
        if query.get('q')==['config']:
            self.reply({'media-endpoint':'http://localhost:8765/media','syndicate-to':[{'uid':'social','name':'Social test'}],'channels':['notes','events'],'visibility':['public','unlisted','private'],'post-types':[{'type':kind,'name':kind.title()} for kind in ['note','photo','reply','article','bookmark','like','repost','event','review','itinerary','code','weight','exercise']]})
        elif query.get('q')==['source']:
            self.reply({'type':['h-entry'],'properties':{'like-of':['https://example.com/article']}})
        else: self.reply({'ok':True})
    def do_POST(self):
        if self.headers.get('Authorization')!='Bearer fixture-token': self.reply({'error':'unauthorized'},401); return
        body=self.rfile.read(int(self.headers.get('Content-Length',0)))
        with LOG.open('a') as log: log.write(json.dumps({'path':self.path,'type':self.headers.get('Content-Type'),'body':body.decode(errors='replace')})+'\n')
        if self.path=='/media': self.reply({},201,{'Location':'http://localhost:8765/photo.jpg'})
        else: self.reply({},201,{'Location':'http://localhost:8765/posts/test'})
if __name__=='__main__':
    print('Quill fixture listening on http://localhost:8765',flush=True)
    ThreadingHTTPServer(('127.0.0.1',8765),Handler).serve_forever()
