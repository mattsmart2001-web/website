// A plausible multi-lap session in the shape lap-coach.js expects:
// {t, x, z, v, thr, brk}, t in seconds, x/z in metres, v in mph.
// A kidney-shaped circuit with four corners of different speeds, driven
// slightly differently each lap, so corner detection and the consistency
// advice both have something real to find.
export function makeSession(laps = 4, hz = 60) {
    const R1 = 420, R2 = 260;                 // two arcs make a kidney
    const pt = u => {                          // u in 0..1 round the lap
        const a = u * Math.PI * 2;
        return [R1 * Math.cos(a), R2 * Math.sin(a) + 90 * Math.sin(2 * a)];
    };
    // Corner centres, and how slow each is.
    const corners = [
        { at: 0.12, vmin: 48,  width: 0.055 },   // slow hairpin
        { at: 0.37, vmin: 92,  width: 0.045 },   // medium
        { at: 0.61, vmin: 132, width: 0.040 },   // fast sweeper
        { at: 0.85, vmin: 58,  width: 0.050 },   // slow
    ];
    const out = [];
    let t = 0;
    for (let lap = 0; lap < laps; lap++) {
        // Each lap a touch different: the driver brakes a bit early or late
        // and carries a bit more or less speed.
        const wobble = [0, 0.004, -0.003, 0.006][lap % 4];
        const carry  = [1, 0.985, 1.01, 0.97][lap % 4];
        const samples = [];
        for (let i = 0; i < hz * 70; i++) {       // ~70 s a lap
            const u = i / (hz * 70);
            let v = 185, brk = 0, thr = 100;
            for (const c of corners) {
                const d = Math.abs(((u - (c.at + wobble)) % 1 + 1.5) % 1 - 0.5);
                if (d < c.width) {
                    const k = 1 - d / c.width;           // 0 at the edges, 1 at the apex
                    v = Math.min(v, c.vmin * carry + (185 - c.vmin) * (1 - k));
                    // brake on the way in, throttle on the way out
                    const before = (((u - (c.at + wobble)) % 1 + 1.5) % 1) < 0.5;
                    brk = before ? Math.min(100, k * 140) : 0;
                    thr = before ? 0 : Math.min(100, k * 160);
                }
            }
            const [x, z] = pt(u);
            samples.push({ t: +(t).toFixed(4), x, z, v, thr, brk });
            t += 1 / hz;
        }
        // GT7's own lap time comes with a real lap and is finer than
        // anything measurable from 60 Hz packets, so the page expects it.
        // Without it the lap chips render as NaN, which is the harness
        // being unrealistic rather than the page being wrong.
        const ms = Math.round((samples[samples.length - 1].t - samples[0].t) * 1000);
        out.push({ name: 'Lap ' + (lap + 1), samples, ms });
    }
    return out;
}
