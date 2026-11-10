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

    node orientation.mjs

answers which way up a GT7 lap belongs on a map, from laps already driven
rather than from reasoning about coordinate systems. A reflection keeps
the shape, the corner sequence and the lap length, and changes only which
way round the lap runs, so that is what it measures: every recorded lap
turns clockwise when z is drawn upward, and two of those circuits are
driven anticlockwise in life. So z goes down the screen, and the portal's
coaching map, which negated it, was drawing every circuit reflected.

    node rotate.mjs
    node rotate.mjs --mirror

drives the portal's coaching map through every angle its rotator can
reach: that the lap still fits the canvas, that turning it is a turn and
not a distortion, that the buttons and the readout agree, and that the
angle is remembered per circuit across a reload. The second form serves
the page with the reflection put back, and is expected to fail.

It fails on exactly one check, which is the point of running it. Turning
the shape passes either way, because reflecting and then turning is still
turning; only the circulation check notices. A test suite that could not
tell the two apart is how the mirror lasted as long as it did.

These exist because the report is about to be shared with the GTEC driver
portal, and the only safe way to move a working thing is to be able to
photograph it before and after.
