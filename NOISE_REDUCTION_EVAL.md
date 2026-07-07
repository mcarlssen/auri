# Evaluating spectral noise reduction

Spectral noise reduction (Settings → Listening → **Spectral noise reduction
(experimental)**) is **off by default**. CI proves the DSP is correct and
non-destructive — perfect-reconstruction reconstruction, white-noise
attenuation, transient-tone survival, SNR improvement, silence stability,
determinism (`Tests/AuriCoreTests/NoiseReductionTests.swift`) — but it **cannot**
prove that the feature improves *bird detection*. Detection efficacy depends on
BirdNET, which needs the CoreML model and labelled real audio, and can only be
measured on your own recordings. This document is that user-side procedure.

The safety mechanism until you have validated it for your environment is simply
that the feature ships off.

## What to measure

Detection quality on a fixed clip, with the feature **off** vs **on**, at a few
known noise levels. Report **precision / recall / F1** against a ground-truth
species list you trust for that clip.

- **Precision** = correct detections ÷ all detections (did NR add false birds?)
- **Recall** = correct detections ÷ species truly present (did NR hide birds?)
- **F1** = harmonic mean of the two.

Spectral NR is worth enabling only if F1 **improves** (or holds while the audio
is audibly cleaner). If recall drops, NR is eating real birdsong — leave it off.

## Procedure

1. **Pick a clean reference clip** with a known set of species (a recording you
   have already confirmed, or a public labelled clip). Keep it short (1–3 min)
   and re-usable.

2. **Build noisy variants at known SNRs.** Mix in a representative steady noise
   (your actual fan/HVAC/room hiss recorded in silence is ideal) at, e.g.,
   +10 dB, 0 dB, and −5 dB SNR. Keep the bird track identical across variants so
   only the noise differs. Any audio editor or a short `ffmpeg`/`sox`/Python
   `amix` script works; normalize afterwards so input level is constant.

3. **Analyze each variant twice** — once with spectral NR **off**, once **on** —
   using Auri's file analysis (Offline tab → open the clip). Use the *same*
   confidence threshold, window overlap, and (optionally) high-pass setting for
   every run so NR is the only variable. Give the profile a few seconds of the
   clip's noise to learn before the birds matter; front-loading a few seconds of
   pure room noise onto each clip helps it converge.

4. **Record detections.** With **Keep the best recording of each species** on,
   compare the committed detections and their confidences run-to-run; the
   history/Heard tab is the committed-detections record to diff.

5. **Score** precision / recall / F1 per (SNR × on/off) cell against ground
   truth, and tabulate:

   | SNR    | F1 (NR off) | F1 (NR on) | Δ recall | Δ precision |
   |--------|-------------|------------|----------|-------------|
   | +10 dB |             |            |          |             |
   |  0 dB  |             |            |          |             |
   |  −5 dB |             |            |          |             |

6. **Decide.** Enable spectral NR only where it does not reduce recall and F1 is
   at least as good as off. The expected win is at low SNR (loud steady noise);
   at high SNR NR should be roughly neutral. If it is net-negative anywhere you
   care about, keep it off.

## Tuning notes for maintainers

The subtraction is deliberately conservative — over-subtraction factor
`beta = 1.5` and a `floorGain = 0.15` that never fully nulls a bin, since
zeroing bins injects artifacts BirdNET never trained on. If real-world
evaluation motivates changes, `beta`, `floorGain`, and the profile/stationarity
constants live in `SpectralNoiseReducer` in `Auri/Audio/NoiseReduction.swift`.
Re-run the package tests after any change — they gate the math, not the F1.
