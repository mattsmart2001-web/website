// Which way up a GT7 lap goes on a map, settled from laps already driven
// rather than from reasoning about coordinate systems.
//
//     node orientation.mjs
//
// The question is whether a circuit's z should be drawn down the screen,
// the way a canvas's y goes, or up it. One of the two draws every circuit
// as its own reflection, and a reflected map of a track you do not know by
// heart looks entirely convincing, which is how the portal's coaching map
// shipped mirrored while live timing, drawn the other way round, was right
// all along.
//
// A reflection preserves the shape, the corner sequence and the lap
// length. The one thing it reverses is which way round the lap runs, so
// that is what to measure, and the answer needs no new data: lap-coach.js
// already carries the curvature signature of real driven laps, recorded
// for identifying tracks by shape.
//
// A signature is the turn rate at 256 points round the lap, measured with
// atan2(dz, dx) — that is, in a plane with x to the right and z UP. A
// closed lap turns through exactly one full circle, so summing it says
// which way round the lap goes in that plane, and nothing else.
import LapCoach from '../../lap-coach.js';   // CommonJS, so the whole module
const { TRACKS } = LapCoach;

const N = 256;

// Which way these circuits are actually driven, which is the part that has
// to come from outside the data. Interlagos is one of the handful of
// anticlockwise Grand Prix circuits, and Daytona's road course follows the
// oval, which like every American oval runs anticlockwise.
const REAL = {
    'Interlagos': 'anticlockwise',
    'Daytona Road Course': 'anticlockwise',
};

let fails = 0;
console.log('Net turning of each recorded lap, in a plane with z drawn UP:\n');
for (const t of TRACKS) {
    const turns = t.sig.reduce((a, b) => a + b, 0) / N / (2 * Math.PI);
    const onZUp = turns > 0 ? 'anticlockwise' : 'clockwise';
    const real = REAL[t.name];
    console.log('  ' + t.name.padEnd(24) + turns.toFixed(3).padStart(7)
        + ' turns  ->  ' + onZUp.padEnd(14)
        + (real ? 'really ' + real : 'direction not asserted here'));
    if (Math.abs(Math.abs(turns) - 1) > 0.02) {
        console.log('      ! a closed lap should turn through exactly one circle');
        fails++;
    }
    if (real && onZUp === real) {
        console.log('      ! drawing z upward reproduces the real direction here,'
                  + ' which contradicts the other tracks');
        fails++;
    }
}

console.log('\nEvery lap recorded runs clockwise when z is drawn upward, and the'
    + '\ntwo whose direction is known are driven anticlockwise. So z drawn'
    + '\nupward is the reflection, and z drawn downward, the same way a'
    + "\ncanvas's y runs, is the map. GT7's coordinates go straight onto the"
    + '\ncanvas with nothing negated.');
console.log(fails ? `\n${fails} check(s) FAILED` : '\nchecks passed');
process.exit(fails ? 1 : 0);
