"""Asks Claude whether upstream changes could break the GraphiteOS patches.

Usage: ANTHROPIC_API_KEY=... python3 ci/ai-review.py work/review > work/verdict.json
Prints {"verdict": "ok" | "concern", "summary": "..."}. Any failure gives "concern", so a broken
review never publishes a release on its own.
"""
import json
import pathlib
import sys

import anthropic

MODEL = "claude-opus-5-5"
MAX_CHARS = 600_000

PROMPT = """You are reviewing an automated release of GraphiteOS, a minimal fork of GrapheneOS for the
Pixel 9 Pro. The fork's patches give the built-in display a color e-ink look: SurfaceFlinger forces
GPU composition on the primary display, RenderEngine runs the composited frame through an SkSL
shader, and only every ~66 ms is a new frame shown (other frames re-show the last filtered frame),
while apps keep normal frame pacing. The filter is skipped for listed apps, camera buffers, protected
content and video from calling apps. Screenshots, virtual and external displays must never be
filtered. A second patch points the Updater app at the GraphiteOS GitHub releases.

Below are (1) our patches as they apply to the new GrapheneOS release and (2) the upstream changes
since our previous release, limited to the files our patches touch. The patches applied without
conflicts; your job is to catch semantic problems a clean merge would miss, for example: renamed or
re-purposed functions/fields we rely on, composition flow changes that bypass our hooks, changes to
client composition caching, protected content, screenshot paths, display identification, frame
scheduling, or Updater URL handling. Ignore style.

Give verdict "concern" only for a real risk that a human should look at before phones install this
build, otherwise "ok". Keep the summary to 5 sentences or fewer.
"""

SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["ok", "concern"]},
        "summary": {"type": "string"},
    },
    "required": ["verdict", "summary"],
    "additionalProperties": False,
}


def review(review_dir):
    parts = [f"===== {p.name} =====\n{p.read_text(errors='replace')}"
             for p in sorted(pathlib.Path(review_dir).glob("*.diff"))]
    material = "\n\n".join(parts)
    if len(material) > MAX_CHARS:
        return {"verdict": "concern", "summary": f"Diff too large to review automatically ({len(material)} chars)."}

    client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY
    response = client.beta.messages.create(
        model=MODEL,
        max_tokens=16000,
        betas=["server-side-fallback-2026-07-01"],
        extra_body={"fallbacks": "default"},  # re-run on another model if a safety classifier declines
        output_config={"effort": "high", "format": {"type": "json_schema", "schema": SCHEMA}},
        messages=[{"role": "user", "content": PROMPT + "\n\n" + material}],
    )
    if response.stop_reason != "end_turn":
        return {"verdict": "concern", "summary": f"AI review did not finish (stop_reason: {response.stop_reason})."}
    return json.loads(next(b.text for b in response.content if b.type == "text"))


if __name__ == "__main__":
    try:
        verdict = review(sys.argv[1])
    except Exception as e:  # fail closed
        verdict = {"verdict": "concern", "summary": f"AI review failed: {e}"}
    json.dump(verdict, sys.stdout)
    print()
