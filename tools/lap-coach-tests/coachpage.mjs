// Drives the existing lap coach page with a synthetic session, so the
// report can be exercised and photographed without a PlayStation. This is
// the baseline any refactor has to keep matching.
import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';
import { makeSession } from './session.mjs';

const ROOT = '/home/user/website';
const OUT = '/tmp/claude-0/-home-user-website/76bb6844-5b68-5ff6-91a9-26d70f1012c6/scratchpad';
const MIME = { '.js':'text/javascript', '.css':'text/css', '.html':'text/html',
               '.json':'application/json', '.svg':'image/svg+xml', '.png':'image/png' };
const tag = process.argv[2] || 'before';

const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 1280, height: 1000 },
                                 deviceScaleFactor: 1 });
const p = await ctx.newPage();
const errs = [];
p.on('pageerror', e => errs.push(e.message));
await p.route('**/*', async route => {
    const url = new URL(route.request().url());
    if (url.hostname === 'local.test') {
        let path = url.pathname; if (path.endsWith('/')) path += 'index.html';
        const f = join(ROOT, path);
        if (existsSync(f)) {
            let body = readFileSync(f);
            // The page's whole script is one IIFE, so nothing inside it is
            // reachable from a test. One line is added to the bytes being
            // SERVED, never to the file, exposing the two things the
            // harness drives and the one it reads back. Everything under
            // test is the real code.
            if (path.endsWith('gt7-lap-coach.html')) {
                body = body.toString().replace(/\n\}\)\(\);\n<\/script>/,
                    '\nwindow.__t = { rec, analyse, get result(){ return result; } };\n})();\n</script>');
            }
            return route.fulfill({ status: 200, body,
                contentType: MIME[extname(f)] || 'application/octet-stream' });
        }
        return route.fulfill({ status: 404, contentType: 'text/plain', body: 'no' });
    }
    return route.fulfill({ status: 200, contentType: 'text/plain', body: '' });
});
await p.goto('https://local.test/gt7-lap-coach.html', { waitUntil: 'load' });
await p.waitForTimeout(600);

const laps = makeSession(4);
const got = await p.evaluate(session => {
    const { rec, analyse } = window.__t;
    rec.laps = session.map(l => ({ name: l.name, samples: l.samples, ms: l.ms }));
    analyse();
    const R = window.__t.result;
    const vis = id => { const e = document.getElementById(id); return !!e && e.innerHTML.trim().length > 0; };
    return {
        reportShown: !document.getElementById('report').classList.contains('hidden'),
        title: document.getElementById('repTitle')?.textContent.trim().slice(0, 40),
        stats: document.getElementById('stats')?.children.length,
        corners: R?.corners.length,
        advice: R?.advice.length,
        drew: { map: !!document.getElementById('m3c')?.width,
                speed: vis('speedBox'), lost: vis('lostBox'),
                delta: vis('deltaBox'), advice: vis('advice'), table: vis('corners') },
    };
}, laps);
console.log(tag, '->', JSON.stringify(got, null, 1));
console.log('errors:', errs.length ? errs.slice(0, 2) : 'none');
const box = await p.$('#report');
await box.screenshot({ path: `${OUT}/coachpage-${tag}.png` });
await b.close();
