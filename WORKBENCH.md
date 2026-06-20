# Palmier Pro Workbench

This fork is for our private video-editing workflow.
It is not intended to become a general-purpose editor fork or an upstream contribution stream.

## Goals

- Keep upstream Palmier Pro easy to fetch and merge.
- Add only features that directly help our story-editing workflow.
- Prefer MCP-exposed editor actions when they save repeated manual work.
- Keep custom changes small, isolated, and documented.

## Near-Term Feature Ideas

- Green-screen/chroma-key workflow for Krutika-style talking-head footage.
- Background replacement presets for story videos.
- Fast story labels: name tags, arrows, location tags, quote bubbles, court/document stamps.
- Project presets for vertical story videos.
- MCP tools that expose our repeated editing gestures.

## What Not To Do

- Do not rebuild a general editor roadmap.
- Do not fork or replace Palmier's generative AI backend.
- Do not make broad refactors unless needed for a feature.
- Do not remove upstream behavior just because we do not need it yet.

## Upstream Sync

Remotes:

- `origin` - our GitHub fork.
- `upstream` - `https://github.com/palmier-io/palmier-pro.git`.

Keep custom work on `workbench/*` branches.
Fetch upstream regularly and merge or rebase intentionally.

Useful commands:

```bash
git fetch upstream
git switch main
git merge upstream/main
git switch workbench/main
git merge main
```

Before custom feature work, create a topic branch:

```bash
git switch -c workbench/chroma-key
```

## Local Launch

Use the workbench launch script instead of upstream `scripts/dev.sh`:

```bash
./scripts/workbench-dev.sh
```

Why:

- Upstream `scripts/dev.sh` uses `--fast`, which expects Palmier's Developer ID certificate.
- The workbench script signs ad-hoc with `SIGNING_IDENTITY=-`.
- It injects placeholder backend values so local editor-only work can launch without Palmier private credentials.

## GPU Chroma-Key Copy

The fork includes a workbench command for Apple Silicon:

```bash
swift run WorkbenchChromaKey \
  --input /absolute/input.mp4 \
  --output /absolute/keyed.mov \
  --similarity 0.16 \
  --softness 0.08 \
  --despill 0.35 \
  --background-rgb 0.94,0.94,0.92
```

It reads video frames with AVFoundation, applies a Core Image chroma-key kernel using a Metal-backed `CIContext`, and writes ProRes 4444. Omit `--background-rgb` to preserve alpha; pass it to bake an opaque background for editors that preview alpha as black.

Current status:

- Fast on M4-class Apple Silicon.
- Useful as a keyed-copy workflow: import the `.mov` into Palmier and place it above the original/raw audio.
- First tuned Krutika pass: `1-raw-keyed-gpu-v3.mov`.
- First baked-background Krutika pass: `1-raw-keyed-gpu-v4-light.mov`.
- Still needs better hair/edge matte cleanup before this becomes the final green-screen solution.
