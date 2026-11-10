# Driving the lap coach without a PlayStation

The coach needs a driven session: four laps of 60 Hz telemetry with
position, speed, throttle and brake. That makes it awkward to change
anything with confidence, because checking your work means going and
driving, and driving the same mistake twice on purpose is harder than it
sounds.

`session.mjs` makes one instead. A kidney-shaped circuit with four corners
of different speeds, driven four times with the braking points moved
slightly and a little more or less speed carried each lap, so corner
detection, the consistency advice and the braking-point spread all have
something real to find.

    node analyse.mjs

runs that session through `lap-coach.js` in Node and prints what it found:
the corners, the theoretical best, and the advice in the order it ranks.
No browser.

    node coachpage.mjs before

loads the real `gt7-lap-coach.html`, feeds it the same session, calls the
page's own `analyse()`, and photographs the report. The tag is just a file
name, so `before` and `after` can be compared across a change.

One thing worth knowing about that second script: the page's whole script
is a single IIFE, so nothing inside it can be reached from a test. The
harness adds one line to the bytes it SERVES, exposing `rec`, `analyse`
and `result`, and never touches the file. Everything under test is the
real code.

These exist because the report is about to be shared with the GTEC driver
portal, and the only safe way to move a working thing is to be able to
photograph it before and after.
