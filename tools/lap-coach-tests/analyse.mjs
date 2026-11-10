import { createRequire } from 'node:module';
import { makeSession } from './session.mjs';
const require = createRequire(import.meta.url);
const LapCoach = require('/home/user/website/lap-coach.js');

const laps = makeSession(4);
console.log('laps:', laps.length, 'samples each:', laps[0].samples.length);
const R = LapCoach.analyse(laps);
console.log('lapLength      ', Math.round(R.lapLength), 'm');
console.log('best lap       ', R.bestTime?.toFixed(3), 's  (', R.names[R.best], ')');
console.log('theoretical    ', R.theoretical?.toFixed(3), 's');
console.log('corners found  ', R.corners.length,
            '(', R.corners.filter(c => c.braking).length, 'braking )');
console.log('longest flat   ', Math.round(R.longestRun?.metres || 0), 'm from', R.longestRun?.opensFrom);
console.log('\nadvice, in the order it ranks:');
for (const a of R.advice.slice(0, 6)) {
    console.log('  [' + String(a.score.toFixed(1)).padStart(5) + ']', a.head);
}
