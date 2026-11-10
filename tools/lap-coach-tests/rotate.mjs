// Drives the portal's coaching map through every orientation the rotator
// can be set to, and checks the two things a rotator can quietly get wrong:
// the lap falling off the edge of the canvas at some angles, and the lap
// being reflected rather than turned.
//
//   node rotate.mjs            the real page
//   node rotate.mjs --mirror   the same page with the projection deliberately
//                              reflected, to prove the check can tell
//
// The reflection is the interesting one, and it is worth being precise
// about which check catches it. Turning the shape is not: reflecting and
// then turning is still turning, so a map with a mirror in it rotates just
// as obediently as one without, and every congruence test passes. What a
// reflection cannot survive is which way round the lap runs, so that is
// what is measured here. `orientation.mjs` is where the ground truth for
// that comes from.
//
// The mirrored run patches one line of the bytes being SERVED, never the
// file, and is expected to fail.
import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';
import { makeSession } from './session.mjs';

const ROOT = '/home/user/website';
const OUT = '/tmp/claude-0/-home-user-website/76bb6844-5b68-5ff6-91a9-26d70f1012c6/scratchpad';
const MIME = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html' };
const MIRROR = process.argv.includes('--mirror');
const DRIVER = { id: 'd1', display_name: 'SparksTheory', slug: 'sparkstheory',
                 coach_beta: true, user_id: 'u1', teams: null, manufacturers: null };

// One line added to the served page, exposing the three things the harness
// drives and reads back. Everything under test is the real code.
const HOOK = "\nwindow.__coach = { rec, analyse, rotSet, get report(){ return report; },"
           + " get rot(){ return mapRot; } };\n})();\n\ninit();";

const fails = [];
const check = (ok, what) => { if (!ok) fails.push(what); return ok; };

const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 1180, height: 1000 },
                                 deviceScaleFactor: 1 });
const errs = [];

async function serve(p) {
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
            if (path === '/endurance/profile/index.html') {
                body = body.toString().replace(/\n\}\)\(\);\n\ninit\(\);/, HOOK);
                // The projected lap, as drawn, before the fit scales it.
                // The fit only scales and shifts, so which way round the
                // lap runs is already decided by these two arrays.
                body = body.replace('        const pad = 34;',
                    '        window.__proj = { x: Array.from(mx), y: Array.from(my) };\n'
                    + '        const pad = 34;');
                if (MIRROR) {
                    const before = body;
                    body = body.replace('const ux = xs[i], uy = zs[i];',
                                        'const ux = xs[i], uy = -zs[i];   /* reflected on purpose */');
                    if (body === before) throw new Error('could not plant the mirror');
                }
            }
            return route.fulfill({ status: 200, body,
                contentType: MIME[extname(f)] || 'application/octet-stream' });
        }
        return route.fulfill({ status: 200, contentType: 'text/plain', body: '' });
    });
}

// Open the portal on the coaching tab with a session already analysed.
async function open(session) {
    const p = await ctx.newPage();
    await serve(p);
    await p.goto('https://local.test/endurance/profile/', { waitUntil: 'load' });
    await p.waitForTimeout(900);
    await p.evaluate(() => window.showTab('coach'));
    await p.waitForTimeout(300);
    await p.evaluate(s => {
        const { rec, analyse } = window.__coach;
        rec.laps = s.map(l => ({ name: l.name, samples: l.samples, ms: l.ms }));
        analyse();
    }, session);
    await p.waitForTimeout(200);
    return p;
}

// The drawn line, as a coarse grid of which cells it passes through.
//
// Only the track is counted. Its colours are the blue speed ramp, from
// (26,72,140) to (198,241,255), every one of them more blue than red; the
// markers and labels on top are red, gold, white and near-black, none of
// which are. So one test on the pixel keeps the line and drops the
// furniture, which matters because the furniture is drawn upright and is
// not supposed to turn with the map.
//
// The grid is laid over the line's own bounding box rather than over the
// canvas, because the map refits itself at every angle: a circuit longer
// than it is wide is drawn larger side-on than end-on, and comparing raw
// pixels would call that difference a change of shape. Normalising each
// render to its own box takes the refit out and leaves the shape, and
// since a quarter turn swaps the box's sides, the normalised grids still
// line up exactly under a quarter, a half or three quarters.
const GRID = 36;
async function inkGrid(p) {
    return await p.evaluate(N => {
        const cv = document.getElementById('coach-map');
        const g = cv.getContext('2d');
        const { width: W, height: H } = cv;
        const d = g.getImageData(0, 0, W, H).data;
        const px = [];
        let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
        for (let y = 0; y < H; y++) {
            for (let x = 0; x < W; x++) {
                const i = (y * W + x) * 4;
                if (d[i + 3] < 128 || d[i + 2] - d[i] < 20) continue;
                px.push(x, y);
                if (x < x0) x0 = x; if (x > x1) x1 = x;
                if (y < y0) y0 = y; if (y > y1) y1 = y;
            }
        }
        const cells = new Uint8Array(N * N);
        const sx = Math.max(1, x1 - x0), sy = Math.max(1, y1 - y0);
        for (let i = 0; i < px.length; i += 2) {
            const c = Math.min(N - 1, ((px[i] - x0) / sx * N) | 0);
            const r = Math.min(N - 1, ((px[i + 1] - y0) / sy * N) | 0);
            cells[r * N + c] = 1;
        }
        return { cells: Array.from(cells), ink: px.length / 2,
                 box: { x0, x1, y0, y1 }, W, H, rot: window.__coach.rot };
    }, GRID);
}

// Two grids compared after one of them is turned by a quarter, a half or
// three quarters. A turn that was really a reflection does not line up
// under any of these, which is the point.
function turned(cells, N, quarters) {
    const out = new Uint8Array(N * N);
    for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) {
        if (!cells[r * N + c]) continue;
        let rr = r, cc = c;
        for (let q = 0; q < quarters; q++) { const t = rr; rr = cc; cc = N - 1 - t; }
        out[rr * N + cc] = 1;
    }
    return out;
}
// How much of one grid is not in the other, counting a cell as found if
// the other grid is lit anywhere alongside it.
//
// The slack of one cell is for line thickness, not for shape. The map
// refits at every angle, so a four pixel line covers a different share of
// a cell end-on than side-on, and cells along the edge of the line light
// or not depending on where the line happens to fall across them. A real
// difference of shape moves the line much further than a cell: a
// reflection of this circuit misses by a third of the grid.
function missing(a, b, N) {
    let miss = 0;
    for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) {
        if (!a[r * N + c]) continue;
        let near = false;
        for (let dr = -1; dr <= 1 && !near; dr++)
            for (let dc = -1; dc <= 1 && !near; dc++) {
                const rr = r + dr, cc = c + dc;
                if (rr >= 0 && rr < N && cc >= 0 && cc < N && b[rr * N + cc]) near = true;
            }
        if (!near) miss++;
    }
    return miss;
}
function diff(a, b, N) {
    let on = 0;
    for (let i = 0; i < a.length; i++) if (a[i] || b[i]) on++;
    return on ? (missing(a, b, N) + missing(b, a, N)) / on : 1;
}

const laps = makeSession(4);
// The same circuit at 60%, standing in for a second track, to show one
// track's remembered angle does not become every track's.
const small = laps.map(l => ({ ...l,
    samples: l.samples.map(s => ({ ...s, x: s.x * 0.6, z: s.z * 0.6 })) }));

const p = await open(laps);

// 1. The lap fits, at every angle the control can reach.
const PAD = 34, SLACK = 6;
const base = await inkGrid(p);
check(base.ink > 2000, `the map drew almost nothing (${base.ink} px of line)`);
let worst = { margin: 1e9 };
for (let deg = 0; deg < 360; deg += 15) {
    await p.evaluate(d => window.__coach.rotSet(d), deg);
    const got = await inkGrid(p);
    check(got.rot === deg, `set ${deg}° and the page says ${got.rot}°`);
    const m = Math.min(got.box.x0, got.box.y0,
                       got.W - 1 - got.box.x1, got.H - 1 - got.box.y1);
    if (m < worst.margin) worst = { margin: m, deg };
    check(m >= PAD - SLACK,
        `at ${deg}° the lap comes within ${m}px of the edge, inside the ${PAD}px pad`);
    check(got.ink > base.ink * 0.5,
        `at ${deg}° only ${got.ink}px of line was drawn, against ${base.ink}px at rest`);
}

// 2. The lap runs round the screen the way it was driven.
//
//    The synthetic session is generated as [R1·cos a, R2·sin a + …] with a
//    increasing, so in GT7's own coordinates it circulates one particular
//    way, and on a north-up map, where z grows downward, that is clockwise.
//    A canvas's y also grows downward, so it has to come out clockwise on
//    screen too, and a positive shoelace is what clockwise looks like with
//    y pointing down.
//
//    This is the check a reflection cannot pass, and the only one. It is
//    also the check that was missing, which is how a mirrored map survived
//    being looked at for weeks.
await p.evaluate(() => window.__coach.rotSet(0));
const area = await p.evaluate(() => {
    const { x, y } = window.__proj;
    let s = 0;
    for (let i = 0; i < x.length; i++) {
        const j = (i + 1) % x.length;
        s += x[i] * y[j] - x[j] * y[i];
    }
    return s / 2;
});
check(area > 0, `the lap is drawn running anticlockwise on screen `
    + `(signed area ${area.toFixed(0)}), so the map is reflected`);

// 3. It is the same shape, turned. A quarter, a half and three quarters are
//    the angles that land back on the grid exactly, so they are the ones
//    worth comparing. This says the rotation is a rotation; it says nothing
//    about which way round the lap runs, which is what the check above is
//    for.
await p.evaluate(() => window.__coach.rotSet(0));
const at0 = (await inkGrid(p)).cells;
const TOL = 0.04;                  // see missing(): a reflection misses by ~0.3
const shape = {};
for (const [deg, quarters] of [[90, 1], [180, 2], [270, 3]]) {
    await p.evaluate(d => window.__coach.rotSet(d), deg);
    const got = await inkGrid(p);
    const d = diff(got.cells, turned(at0, GRID, quarters), GRID);
    shape[deg + '°'] = +d.toFixed(3);
    check(d <= TOL, `at ${deg}° the shape does not match the lap turned ${deg}° (${(d * 100).toFixed(1)}% of cells differ)`);
}

// 4. The buttons and the readout agree with each other.
await p.evaluate(() => window.__coach.rotSet(0));
await p.click('#coach-rot-half');
const half = await p.evaluate(() => ({ rot: window.__coach.rot,
    slider: +document.getElementById('coach-rot').value,
    shown: document.getElementById('coach-rot-deg').textContent }));
check(half.rot === 180 && half.slider === 180 && half.shown === '180°',
    `half turn left it at ${JSON.stringify(half)}`);
await p.click('#coach-rot-cw');
await p.click('#coach-rot-ccw');
await p.click('#coach-rot-ccw');
const stepped = await p.evaluate(() => window.__coach.rot);
check(stepped === 165, `three steps from 180 (+15, -15, -15) left ${stepped}°`);
// And it wraps rather than sticking at either end.
await p.evaluate(() => window.__coach.rotSet(0));
await p.click('#coach-rot-ccw');
const wrapped = await p.evaluate(() => window.__coach.rot);
check(wrapped === 345, `one step back from 0 left ${wrapped}°, not 345°`);

// 5. It is remembered, per circuit, across a reload.
await p.evaluate(() => window.__coach.rotSet(135));
const stored = await p.evaluate(() => localStorage.getItem('gtec.coach.maprot'));
await p.close();

const p2 = await open(laps);
const back = await p2.evaluate(() => ({ rot: window.__coach.rot,
    slider: +document.getElementById('coach-rot').value }));
check(back.rot === 135 && back.slider === 135,
    `after a reload the map came back at ${JSON.stringify(back)}, not 135°`);

// A different track starts where it always did, and does not take the
// other one's angle with it.
await p2.evaluate(s => {
    const { rec, analyse } = window.__coach;
    rec.laps = s.map(l => ({ name: l.name, samples: l.samples, ms: l.ms }));
    analyse();
}, small);
const other = await p2.evaluate(() => window.__coach.rot);
check(other === 0, `a second circuit opened at ${other}°, not square on`);
await p2.evaluate(() => window.__coach.rotSet(45));
await p2.evaluate(s => {
    const { rec, analyse } = window.__coach;
    rec.laps = s.map(l => ({ name: l.name, samples: l.samples, ms: l.ms }));
    analyse();
}, laps);
const backAgain = await p2.evaluate(() => window.__coach.rot);
check(backAgain === 135, `going back to the first circuit gave ${backAgain}°, not 135°`);

await p2.evaluate(() => window.__coach.rotSet(180));
await p2.waitForTimeout(150);
const card = await p2.$('#card-coach-map');
await card.screenshot({ path: `${OUT}/coachmap-rot${MIRROR ? '-mirror' : ''}.png` });
await p2.close();
await b.close();

console.log(MIRROR ? 'MIRRORED PAGE (expected to fail)' : 'real page');
console.log(' line pixels at rest :', base.ink);
console.log(' tightest fit        :', worst.margin + 'px of margin, at ' + worst.deg + '°');
console.log(' shape after turning :', JSON.stringify(shape), `(tolerance ${TOL})`);
console.log(' remembered          :', stored);
console.log(' page errors         :', errs.length ? errs.slice(0, 2) : 'none');
console.log(fails.length ? ' FAILURES:\n   - ' + fails.join('\n   - ')
                         : ' all checks passed');
process.exit(fails.length || errs.length ? 1 : 0);
