# DaqPal

## Why this exists

Every hobby electronics bench eventually runs into the same wall. You have a cheap multimeter, an old bench power supply, or some scientific instrument with a perfectly good digital display, and absolutely no way to get that number into a spreadsheet without buying a proper data acquisition (DAQ) system. Real DAQ hardware is expensive, often locked to specific instruments, and overkill for someone who just wants to log a voltage over time for a school lab report or a weekend project.

I got tired of squinting at a seven-segment display, manually typing numbers into a spreadsheet, or trying to time a stopwatch against a reading that refreshes twice a second. Meanwhile my phone already has a camera good enough to read that same display far faster and more consistently than I can by hand. There was no reason that data should be trapped behind a piece of glass just because the instrument predates USB.

DaqPal is the answer to that annoyance: point a phone camera at any instrument display, tell it roughly what the display looks like, and let it turn what would otherwise be a manual transcription chore into a clean, timestamped CSV file.

## What it actually does

Instead of treating this as a generic "read text from an image" problem, DaqPal leans on the fact that most instrument displays are extremely predictable. A digital multimeter doesn't show arbitrary text, it shows a fixed number of digits, in a fixed position, with a decimal point that moves in known ways. Once the app knows that shape, recognizing the display stops being a hard OCR problem and becomes a much simpler constrained one: figure out which of ten digits is lit up in each known slot.

That distinction matters a lot in practice. It means:

- Higher accuracy than throwing a generic OCR model at the whole frame
- Confidence scoring per digit, not just per reading
- The ability to tell a real value change apart from a flickering LCD or a blurry frame
- Rejection of readings that don't make physical sense (a voltage that jumps 70V between frames didn't actually happen)

The system deliberately keeps camera frame rate, OCR processing rate, and the instrument's actual measurement rate as separate ideas. A 240 FPS camera does not mean you suddenly have 240 real measurements a second, and DaqPal doesn't pretend otherwise.

## Who this is for

This is built for labs and school projects first, not industrial deployment. If you're a student trying to log a titration curve, a hobbyist characterizing a circuit, or a lab TA tired of transcribing multimeter readings by hand, this is meant to save you the tedium without asking you to buy dedicated equipment. It should work with whatever instrument is already sitting on the bench, no serial cable or proprietary software required.

## Current status

This project is in early, active development, currently starting as a native iOS app (Swift, SwiftUI, AVFoundation, Apple Vision OCR) to validate the core idea on real hardware before expanding further. The near-term goal is a working end-to-end loop: point the camera at a display, select the region of interest, confirm the display format, and get a live reading on screen. Recording, CSV export, and more advanced recognition (digit-level segmentation, seven-segment specific models, format inference for unknown instruments) build on top of that foundation.

See `Visual_Instrument_Data_Logger_Agent_Development_Specification.md` for the full technical breakdown of the architecture, recognition pipeline, and development roadmap.

## Design philosophy

A few principles guide every decision here:

1. Don't trust a single frame. Use temporal consistency across frames to resolve uncertain digits.
2. A rejected reading is better than a wrong one. When in doubt, flag it rather than log garbage into someone's dataset.
3. The more the app knows about an instrument's display, the less it needs to guess.
4. Processing stays on-device by default. Lab data shouldn't need to leave the room to get read.

## License

DaqPal is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). You're free to use, modify, and share it for any noncommercial purpose — personal projects, education, and research included. Commercial use requires a separate license from the copyright holder, which keeps the door open for commercializing the project later.
