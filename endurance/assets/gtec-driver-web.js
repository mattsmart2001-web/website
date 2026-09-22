/* GTEC driver web — a slow flight through the whole registered grid.

   Every driver is a light. Team-mates are joined by a strand, because a
   crew is the unit that actually races together; fainter lines link
   teams sharing a manufacturer. The camera travels forward through the
   field with real perspective, so crews approach out of depth, swell,
   and sweep past the edges of the frame.

   Self-contained: injects its own canvas and styles, reads the roster
   straight from Supabase, and sizes the field to however many drivers
   it finds. Pages just include this script.

   If the roster can't be read the canvas stays empty, which leaves the
   page's own dark background showing — nothing to clean up. */
(function () {
    'use strict';

    if (document.getElementById('gtec-driver-web')) return;
    if (!window.supabase || !window.GTEC_CONFIG) return;

    var canvas = document.createElement('canvas');
    canvas.id = 'gtec-driver-web';
    var style = document.createElement('style');
    style.id = 'gtec-driver-web-style';
    style.textContent =
        '#gtec-driver-web{position:fixed;inset:0;z-index:-1;pointer-events:none;opacity:0.5}';
    document.head.appendChild(style);
    document.body.insertBefore(canvas, document.body.firstChild);

    var ctx = canvas.getContext('2d');
    var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    var DPR = Math.min(2, window.devicePixelRatio || 1);
    var W = 0, H = 0;
    function resize() {
        W = window.innerWidth; H = window.innerHeight;
        canvas.width = W * DPR; canvas.height = H * DPR;
        canvas.style.width = W + 'px'; canvas.style.height = H + 'px';
        ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    }
    window.addEventListener('resize', resize);
    resize();

    // Deterministic placement: the same roster always lays out the same
    // way, so the backdrop doesn't reshuffle itself on every page load.
    function mulberry32(a) {
        return function () {
            a |= 0; a = (a + 0x6D2B79F5) | 0;
            var t = Math.imul(a ^ (a >>> 15), 1 | a);
            t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
    }

    var NEAR = 70;
    var FOCAL = 760;
    var SPEED = 2.6;
    var NAME_THRESHOLD = 0.5; // how close before a driver's name shows

    var DEPTH, SPREAD_X, SPREAD_Y;
    var crews = [];
    var crossLinks = [];
    var camZ = 0, t = 0, running = false;

    function layout(drivers) {
        // One crew per team; drivers without a team fly solo.
        var byTeam = {}, solo = [];
        drivers.forEach(function (d) {
            if (d.current_team_id) {
                (byTeam[d.current_team_id] = byTeam[d.current_team_id] || []).push(d);
            } else {
                solo.push(d);
            }
        });

        var groups = [];
        Object.keys(byTeam).forEach(function (id) {
            var members = byTeam[id];
            groups.push({ members: members, manu: (members[0].manufacturers || {}).id || null });
        });
        solo.forEach(function (d) {
            groups.push({ members: [d], manu: (d.manufacturers || {}).id || null });
        });
        if (!groups.length) return false;

        // Size the volume to the roster so the field reads at the same
        // density whether eight crews have signed up or eighty.
        var n = groups.length;
        DEPTH = Math.max(900, Math.min(6000, n * 60));
        SPREAD_X = Math.max(600, Math.min(1700, 600 + n * 13));
        SPREAD_Y = SPREAD_X * 0.68;

        var rand = mulberry32(1337 + n);
        crews = groups.map(function (g) {
            var cx = (rand() - 0.5) * 2 * SPREAD_X;
            var cy = (rand() - 0.5) * 2 * SPREAD_Y;
            var cz = rand() * DEPTH;
            var sep = 42 + rand() * 46;
            var a0 = rand() * Math.PI * 2;
            var tilt = (rand() - 0.5) * 0.9;
            var k = g.members.length;
            var lights = g.members.map(function (d, i) {
                var a = a0 + (i / k) * Math.PI * 2;
                var spread = k === 1 ? 0 : sep;
                return {
                    dx: Math.cos(a) * spread,
                    dy: Math.sin(a) * spread * 0.7,
                    dz: (k === 1 ? 0 : Math.cos(a) * tilt * sep),
                    name: (d.display_name || '').toUpperCase()
                };
            });
            return { x: cx, y: cy, z: cz, manu: g.manu, lights: lights };
        });

        // Nearest same-manufacturer crew, worked out once.
        var byManu = {};
        crews.forEach(function (c) { if (c.manu) (byManu[c.manu] = byManu[c.manu] || []).push(c); });
        crossLinks = [];
        Object.keys(byManu).forEach(function (m) {
            var g = byManu[m];
            for (var i = 0; i < g.length; i++) {
                var a = g[i], best = null, bestD = Infinity;
                for (var j = 0; j < g.length; j++) {
                    if (i === j) continue;
                    var b = g[j];
                    var dd = (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z);
                    if (dd < bestD) { bestD = dd; best = b; }
                }
                if (best) crossLinks.push([a, best]);
            }
        });
        return true;
    }

    function project(wx, wy, rz) {
        var s = FOCAL / rz;
        return { x: wx * s + W / 2, y: wy * s + H / 2, s: s };
    }
    // Relative depth wrapped into the volume, so the flight loops
    // seamlessly and no crew ever pops into existence.
    function relZ(z) {
        var rz = (z - camZ) % DEPTH;
        if (rz < 0) rz += DEPTH;
        return rz < NEAR ? rz + DEPTH : rz;
    }
    function depthAlpha(rz) {
        var far = 1 - Math.max(0, (rz - DEPTH * 0.72) / (DEPTH * 0.28));
        var near = Math.min(1, (rz - NEAR) / 460);
        return Math.max(0, Math.min(far, near));
    }

    function draw() {
        if (!reduceMotion) { camZ += SPEED; t += 0.0016; }

        var camX = Math.sin(t) * 190;
        var camY = Math.sin(t * 0.67 + 1.1) * 130;

        ctx.clearRect(0, 0, W, H);

        for (var c = 0; c < crossLinks.length; c++) {
            var ca = crossLinks[c][0], cb = crossLinks[c][1];
            var rza = relZ(ca.z), rzb = relZ(cb.z);
            if (Math.abs(rza - rzb) > DEPTH * 0.45) continue; // wrapped apart
            var aa = depthAlpha(rza), ab = depthAlpha(rzb);
            if (aa <= 0 || ab <= 0) continue;
            var pa = project(ca.x - camX, ca.y - camY, rza);
            var pb = project(cb.x - camX, cb.y - camY, rzb);
            ctx.strokeStyle = 'rgba(255,209,102,' + (0.055 * Math.min(aa, ab)).toFixed(3) + ')';
            ctx.lineWidth = 1;
            ctx.beginPath(); ctx.moveTo(pa.x, pa.y); ctx.lineTo(pb.x, pb.y); ctx.stroke();
        }

        var order = crews.map(function (cr) { return { cr: cr, rz: relZ(cr.z) }; });
        order.sort(function (a, b) { return b.rz - a.rz; });

        for (var i = 0; i < order.length; i++) {
            var cr = order[i].cr, rz = order[i].rz;

            // Each light carries its own depth, so it fades on its own
            // schedule rather than the crew blinking out as one.
            var pts = [];
            for (var k = 0; k < cr.lights.length; k++) {
                var L = cr.lights[k];
                var lrz = rz + L.dz;
                if (lrz < NEAR) { pts.push(null); continue; }
                var p = project(cr.x + L.dx - camX, cr.y + L.dy - camY, lrz);
                p.a = depthAlpha(lrz);
                p.prox = Math.min(1, FOCAL / lrz);
                p.name = L.name;
                pts.push(p.a > 0 ? p : null);
            }

            // the strand that says "these two race together"
            var ring = pts.length === 2 ? [[0, 1]] : [];
            if (pts.length > 2) {
                for (var r = 0; r < pts.length; r++) ring.push([r, (r + 1) % pts.length]);
            }
            for (var e = 0; e < ring.length; e++) {
                var pA = pts[ring[e][0]], pB = pts[ring[e][1]];
                if (!pA || !pB) continue;
                var sa = Math.min(pA.a, pB.a), sp = (pA.prox + pB.prox) / 2;
                ctx.strokeStyle = 'rgba(255,214,120,' + (sa * (0.18 + sp * 0.5)).toFixed(3) + ')';
                ctx.lineWidth = Math.max(0.7, sp * 2.6);
                ctx.beginPath(); ctx.moveTo(pA.x, pA.y); ctx.lineTo(pB.x, pB.y); ctx.stroke();
            }

            for (var q = 0; q < pts.length; q++) {
                var p2 = pts[q];
                if (!p2) continue;
                var rad = Math.max(0.9, p2.s * 2.6);
                var g = ctx.createRadialGradient(p2.x, p2.y, 0, p2.x, p2.y, rad * 5);
                g.addColorStop(0, 'rgba(255,226,164,' + (p2.a * (0.3 + p2.prox * 0.5)).toFixed(3) + ')');
                g.addColorStop(1, 'rgba(255,226,164,0)');
                ctx.fillStyle = g;
                ctx.beginPath(); ctx.arc(p2.x, p2.y, rad * 5, 0, Math.PI * 2); ctx.fill();

                ctx.fillStyle = 'rgba(255,244,223,' + (p2.a * (0.5 + p2.prox * 0.5)).toFixed(3) + ')';
                ctx.beginPath(); ctx.arc(p2.x, p2.y, rad, 0, Math.PI * 2); ctx.fill();
            }

            // Names: opacity depends only on that driver's own distance,
            // so a name ramps in once and rides out. Nothing competes for
            // a slot, so nothing blinks.
            var lowest = -Infinity, lowIdx = -1;
            for (var w = 0; w < pts.length; w++) {
                if (pts[w] && pts[w].y > lowest) { lowest = pts[w].y; lowIdx = w; }
            }
            for (var n2 = 0; n2 < pts.length; n2++) {
                var pn = pts[n2];
                if (!pn || !pn.name) continue;
                if (pn.prox <= NAME_THRESHOLD) continue;
                if (pn.x < -220 || pn.x > W + 220) continue;
                var na = pn.a * Math.min(1, (pn.prox - NAME_THRESHOLD) / 0.18) * 0.7;
                if (na <= 0.015) continue;
                ctx.font = '600 ' + Math.min(15, 8 + pn.prox * 7).toFixed(1) + "px 'Orbitron', sans-serif";
                ctx.fillStyle = 'rgba(255,238,205,' + na.toFixed(3) + ')';
                // lowest light labels below, the rest above, so a tight
                // pair doesn't stack both names in the same place
                ctx.fillText(pn.name, pn.x + 12, pn.y + (n2 === lowIdx && pts.length > 1 ? 15 : -7));
            }
        }

        if (running) requestAnimationFrame(draw);
    }

    function start() {
        if (running) return;
        running = true;
        requestAnimationFrame(draw);
    }
    function stop() { running = false; }

    // No point burning frames on a tab nobody is looking at.
    document.addEventListener('visibilitychange', function () {
        if (document.hidden) stop(); else if (crews.length) start();
    });

    var sb = window.supabase.createClient(window.GTEC_CONFIG.supabaseUrl, window.GTEC_CONFIG.supabaseAnonKey);
    sb.from('drivers')
        .select('id, display_name, current_team_id, manufacturers(id)')
        .order('display_name')
        .then(function (res) {
            if (res.error || !res.data || !res.data.length) return;
            if (!layout(res.data)) return;
            if (reduceMotion) { draw(); return; }  // one still frame, no loop
            start();
        });
})();
