#!/usr/bin/env python3
"""Local-only Micropub fixture. No real accounts, tokens or posts."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import json
from pathlib import Path
LOG=Path('/private/tmp/quill-fixture-requests.jsonl')
POSTS=[
    {'type':['h-entry'],'properties':{'url':['http://localhost:8765/posts/heron'],'photo':[{'value':'http://localhost:8765/photo.jpg','alt':'A heron on the river'}],'published':['2026-11-15T09:00:00Z']}},
    {'type':['h-entry'],'properties':{'url':['http://localhost:8765/posts/coffee'],'content':['Trying the new café on Atlantic'],'category':['food'],'published':['2026-11-14T09:00:00Z']}},
    {'type':['h-entry'],'properties':{'url':['http://localhost:8765/posts/notes'],'name':['Notes on Micropub'],'content':[{'html':'<p>Listing posts is part of the spec.</p>'}],'published':['2026-11-13T09:00:00Z']}},
    {'type':['h-entry'],'properties':{'url':['http://localhost:8765/posts/like'],'like-of':['https://example.com/article'],'published':['2026-11-12T09:00:00Z']}},
    {'type':['h-event'],'properties':{'url':['http://localhost:8765/posts/party'],'name':['Party'],'start':['2026-12-01T19:00:00-05:00'],'published':['2026-11-11T09:00:00Z']}},
]
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def reply(self,data,status=200,headers=None):
        body=json.dumps(data).encode(); self.send_response(status)
        self.send_header('Content-Type','application/json')
        for key,value in (headers or {}).items(): self.send_header(key,value)
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        query=parse_qs(urlparse(self.path).query)
        if urlparse(self.path).path=='/photo.jpg':
            body=(Path(__file__).resolve().parents[1]/'QuillNative/Assets.xcassets/AppIcon.appiconset/AppIcon.png').read_bytes()
            self.send_response(200); self.send_header('Content-Type','image/png'); self.end_headers(); self.wfile.write(body); return
        if query.get('q')==['config']:
            self.reply({'media-endpoint':'http://localhost:8765/media','syndicate-to':[{'uid':'social','name':'Social test'}],'channels':['notes','events'],'visibility':['public','unlisted','private'],'post-types':[{'type':kind,'name':kind.title()} for kind in ['note','photo','reply','article','bookmark','like','repost','event','review','itinerary','code','weight','exercise']]})
        elif query.get('q')==['source'] and 'url' not in query:
            page=0 if 'after' not in query else int(query['after'][0])
            items=POSTS[page*2:page*2+2]
            self.reply({'items':items,**({'paging':{'after':str(page+1)}} if page*2+2<len(POSTS) else {})})
        elif query.get('q')==['source']:
            match=[p for p in POSTS if p['properties']['url'][0]==query['url'][0]]
            self.reply(match[0] if match else {'type':['h-entry'],'properties':{'like-of':['https://example.com/article']}})
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
