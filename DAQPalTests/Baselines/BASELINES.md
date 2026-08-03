# Recorded regression baselines

(Named `BASELINES.md` rather than `README.md`: the test target's resource copy
is flat, and `Fixtures/README.md` already owns that basename.)

One file per sweep. Each pins the numbers that sweep produced at the commit the
file was last written, and `RegressionBaselineTests` fails when a run drops
below them by more than the tolerance in `RegressionThresholds`.

These files are reviewed, not generated on demand. A diff here is a claim that
the pipeline's measured accuracy changed, and it belongs in the same commit as
the change that caused it.

## Reading a file

    format: 1                    on-disk shape; a mismatch fails loudly
    name: pose-sweep             also the file stem
    cases: 200                   corpus size the rates were measured over
    exactRate: 0.987000          digits AND decimal correct
    digitAccuracy: 0.994000      digits correct, of readings that were detected
    decimalAccuracy: 0.968000    decimal correct, of readings whose digits were
    detectionRate: 1.000000      produced any reading at all
    meanIoU: 0.912000            `none` for sweeps without geometry truth
    p95LatencyMS: 41.200         Debug-build timing; see below

Rates carry six decimals and latency three so an unchanged run re-serializes to
identical bytes. Never hand-edit a value: the point of the file is that its
numbers were measured.

## Re-recording after a deliberate improvement

    DAQPAL_RECORD_BASELINE=pose-sweep xcodebuild test \
      -project DAQPal.xcodeproj -scheme DAQPal \
      -destination "platform=iOS Simulator,name=iPhone 16" \
      -only-testing:DAQPalTests/RegressionBaselineTests

The variable must name exactly one baseline. `=1`, `=all` and friends are
rejected: a blanket switch would let a single distracted run rewrite every
recorded number, which is the failure this whole mechanism exists to prevent.
Recording several baselines takes several runs.

Then commit the changed `.baseline` file with the change that moved it.

## Latency is not a performance budget

`p95LatencyMS` comes from a Debug build on whatever machine ran the suite, where
per-pixel Swift runs up to ~50x slower than Release. It is compared with a
multiplicative tolerance and only catches order-of-magnitude drift — an extra
full-frame pass, a second Vision request. Shipping performance is asserted in
`PipelineBudgetTests` against a Release build; do not quote a number from this
directory as a shipping cost.

## selftest-fixture.baseline

Not a sweep. It is a fixed file the checker's own tests load to prove that
on-disk resolution, parsing and byte-identical re-serialization work. Leave it
alone; changing it fails `RegressionBaselineTests`.
