// Forty-five laps through the coaching tab's own recorder, to see what it
// keeps and what it costs.
//
//     node laps.mjs
//
// The report is rebuilt from scratch at every line crossing, so without a
// limit on how many laps it is built from, a long stint gets slower and
// heavier for as long as it goes on. At Le Mans lap length the analyser
// takes about 18 ms a lap, so 137 laps is two and a half seconds of
// thinking at every crossing and about 300 MB of samples held.
//
// This drives the real page with real packets, through the real recorder,
// and checks the window holds: laps kept, laps named by how many have been
// driven rather than how many are kept, the session best surviving laps
// that have aged out, and the analysis staying flat rather than climbing.
import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';
import { makeSession } from './session.mjs';

const ROOT = '/home/user/website';
const MIME = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html' };
const DRIVER = { id: 'd1', display_name: 'SparksTheory', slug: 'sparkstheory',
                 coach_beta: true, user_id: 'u1', teams: null, manufacturers: null };
const LAPS = 45;

const HOOK = "\nwindow.__coach = { rec, record, analyse, MAX_LAPS,"
           + " get report(){ return report; } };\n})();\n\ninit();";

const fails = [];
const check = (ok, what) => { if (!ok) fails.push(what); };

const b = await chromium.launch();
const p = await (await b.newContext({ viewport: { width: 1180, height: 900 } })).newPage();
const errs = [];
p.on('pageerror', e => errs.push(e.message));
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
        let body = readFileSync(f);
        if (path === '/endurance/profile/index.html')
            body = body.toString().replace(/\n\}\)\(\);\n\ninit\(\);/, HOOK);
        return route.fulfill({ status: 200, body,
            contentType: MIME[extname(f)] || 'application/octet-stream' });
    }
    return route.fulfill({ status: 200, contentType: 'text/plain', body: '' });
});
await p.goto('https://local.test/endurance/profile/', { waitUntil: 'load' });
await p.waitForTimeout(900);
await p.evaluate(() => window.showTab('coach'));
await p.waitForTimeout(300);

// One lap of the synthetic circuit, as the packets a connector sends. The
// quickest lap is deliberately an early one, so that by the end it has aged
// out of the window and the session best has to have been kept separately.
const lap = makeSession(1)[0].samples;
const FAST_LAP = 4;

const out = await p.evaluate(async ({ samples, laps, fastLap }) => {
    const { record } = window.__coach;
    const times = [];
    let pid = 0;
    for (let n = 0; n <= laps; n++) {
        const ms = n === fastLap ? 68000 : 70000 + (n * 37) % 900;
        for (let i = 0; i < samples.length; i++) {
            const s = samples[i];
            record({ packetId: pid++, vehicleId: 7, lapCount: n,
                posX: s.x, posY: 0, posZ: s.z, speed: s.v / 0.621371,
                throttle: s.thr, brake: s.brk,
                lastLap: n === 0 ? 0 : (n === fastLap + 1 ? 68000 : times[n - 1]) });
        }
        times.push(ms);
        // The lap time the game reports for the lap just finished is read
        // on the first packet of the next one, so it is fed in above.
    }
    const t0 = performance.now();
    window.__coach.analyse();
    const ms = performance.now() - t0;
    const rec = window.__coach.rec;
    return { kept: rec.laps.length, max: window.__coach.MAX_LAPS, driven: rec.n,
             first: rec.laps[0]?.name, last: rec.laps[rec.laps.length - 1]?.name,
             best: rec.best, analyseMs: Math.round(ms),
             note: document.getElementById('coach-lapnote')?.textContent,
             reportLaps: window.__coach.report?.times?.length };
}, { samples: lap, laps: LAPS, fastLap: FAST_LAP });

// The lap in progress when recording starts is thrown away, and the lap
// time the game reports arrives on the first packet of the NEXT lap, so
// how many laps this makes is not worth asserting to the unit. What has to
// hold is the relationship between them.
check(out.kept === out.max, `kept ${out.kept} laps, not ${out.max}`);
check(out.driven > out.max + 5,
    `only ${out.driven} laps were driven, which is not enough to test a window of ${out.max}`);
check(out.last === 'Lap ' + out.driven,
    `the newest lap is called "${out.last}" after ${out.driven} laps driven`);
check(out.first === 'Lap ' + (out.driven - out.max + 1),
    `the oldest kept lap is called "${out.first}", so the window is not ${out.max} long`);
check(out.reportLaps === out.max,
    `the report was built from ${out.reportLaps} laps, not ${out.max}`);
// The quickest lap was set early and the window has long since moved past
// it, so it is gone from the analysis and has to have survived anyway.
check(out.best && out.best.ms === 68000,
    `the session best came out as ${JSON.stringify(out.best)}, not the 68000 ms lap`);
check(out.best && out.best.n < out.driven - out.max + 1,
    `the session best is lap ${out.best && out.best.n}, which is still inside the `
    + `window, so this run never tested that it survives falling out of it`);
check(/Session best/.test(out.note || ''),
    `the lap note does not mention the session best: "${out.note}"`);

console.log('laps driven      :', out.driven);
console.log('laps kept        :', out.kept, '(window ' + out.max + ')');
console.log('oldest / newest  :', out.first, '/', out.last);
console.log('session best     :', out.best && (out.best.ms + ' ms on lap ' + out.best.n));
console.log('analyse() at 45  :', out.analyseMs + ' ms');
console.log('note             :', out.note);
console.log('page errors      :', errs.length ? errs.slice(0, 2) : 'none');
console.log(fails.length ? 'FAILURES:\n  - ' + fails.join('\n  - ') : 'all checks passed');
await b.close();
process.exit(fails.length || errs.length ? 1 : 0);
