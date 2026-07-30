---
description: Build, package, validate, and socket-test this clapp (npm run verify)
---
Run `npm run verify`. If it passes, say so briefly. If a step fails, read that
step's output (and `$TMPDIR/clock-verify.log` for the socket step), diagnose, and
fix it — then re-run.

The socket step needs a desktop session: it starts the packaged binary as a GUI
process and drives it with `clock list`. On a headless box that step cannot pass,
and that is a skip, not a bug in the app.
