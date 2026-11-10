// Serves the portal with a real CSP header and a real WebSocket server, to
// show which of the two policies lets the coaching tab reach the connector.
import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';
const ROOT = '/home/user/website';
const MIME = { '.js':'text/javascript', '.css':'text/css', '.html':'text/html' };
const DRIVER = { id:'d1', display_name:'SparksTheory', slug:'sparkstheory',
                 coach_beta:true, user_id:'u1', teams:null, manufacturers:null };
const OLD = "connect-src 'self' https://x.supabase.co wss://x.supabase.co";
const NEW = OLD + " ws://localhost:8765 ws://127.0.0.1:8765";

for (const [label, connect] of [['old CSP', OLD], ['new CSP', NEW]]) {
    const b = await chromium.launch();
    const ctx = await b.newContext({ viewport: { width: 1100, height: 800 } });
    const p = await ctx.newPage();
    const blocked = [];
    p.on('console', m => { if (/Content Security Policy|Refused/i.test(m.text()))
        blocked.push(m.text().slice(0, 80)); });
    await p.route('**/*', async route => {
        const url = new URL(route.request().url());
        if (url.hostname.includes('cdn') || url.pathname.includes('supabase-js')) {
            return route.fulfill({ status: 200, contentType: 'text/javascript', body: `
                const D = ${JSON.stringify(DRIVER)};
                function chain(r){ const o={data:r,error:null};
                  return new Proxy(function(){},{get(t,k){
                    if(k==='then')return(a,b)=>Promise.resolve(o).then(a,b);
                    if(k==='single'||k==='maybeSingle')return()=>Promise.resolve({data:Array.isArray(r)?r[0]??null:r,error:null});
                    return()=>chain(r);},apply:()=>chain(r)});}
                window.supabase={createClient:()=>({rpc:()=>Promise.resolve({data:[],error:null}),
                  from:t=>chain(t==='drivers'?D:t==='user_roles'?{role:'driver'}:[]),
                  channel:()=>({on:()=>({subscribe(){}}),subscribe(){}}),removeChannel:()=>{},
                  storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})},
                  auth:{getSession:async()=>({data:{session:{user:{id:'u1',email:'d@e.test'}}},error:null}),
                        getUser:async()=>({data:{user:{id:'u1'}},error:null}),signOut:async()=>({}),
                        onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}})}})};` });
        }
        if (url.hostname === 'local.test') {
            let path = url.pathname; if (path.endsWith('/')) path += 'index.html';
            const f = join(ROOT, path);
            if (!existsSync(f)) return route.fulfill({ status: 404, body: 'no' });
            const headers = path.startsWith('/endurance/')
                ? { 'Content-Security-Policy': `default-src 'self'; script-src 'self' 'unsafe-inline' cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' fonts.googleapis.com; font-src 'self' fonts.gstatic.com; img-src 'self' data: blob: https:; ${connect};` }
                : {};
            return route.fulfill({ status: 200, body: readFileSync(f), headers,
                contentType: MIME[extname(f)] || 'application/octet-stream' });
        }
        return route.fulfill({ status: 200, contentType: 'text/plain', body: '' });
    });
    await p.goto('https://local.test/endurance/profile/', { waitUntil: 'load' });
    await p.waitForTimeout(1200);
    await p.evaluate(() => window.showTab('coach'));
    await p.waitForTimeout(7500);
    const msg = await p.evaluate(() => document.getElementById('coach-msg')?.textContent);
    console.log(label.padEnd(9), '->', JSON.stringify(msg));
    if (blocked.length) console.log('          browser said:', blocked[0]);
    await b.close();
}
