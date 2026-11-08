"""Asks Claude (via OpenRouter) whether upstream changes could break the GraphiteOS patches.

Usage: python3 ci/ai-review.py work/review > work/verdict.json
Prints {"verdict": "ok" | "concern", "summary": "..."}. Any failure gives "concern", so a broken
review never publishes a release on its own.
"""
import json
import os
import pathlib
import sys
import urllib.request

MODEL = "anthropic/claude-opus-5.5"
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

Answer with only a JSON object: {"verdict": "ok" or "concern", "summary": "<= 5 sentences"}.
Use "concern" only for a real risk that a human should look at before phones install this build.
"""


def review(review_dir):
    parts = []
    for path in sorted(pathlib.Path(review_dir).glob("*.diff")):
        parts.append(f"===== {path.name} =====\n{path.read_text(errors='replace')}")
    material = "\n\n".join(parts)
    if len(material) > MAX_CHARS:
        return {"verdict": "concern", "summary": f"Diff too large to review automatically ({len(material)} chars)."}
    request = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps({
            "model": MODEL,
            "messages": [{"role": "user", "content": PROMPT + "\n\n" + material}],
            "max_tokens": 2000,
        }).encode(),
        headers={"Authorization": f"Bearer {os.environ['OPENROUTER_API_KEY']}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        text = json.load(response)["choices"][0]["message"]["content"]
    result = json.loads(text[text.index("{"):text.rindex("}") + 1])
    if result.get("verdict") not in ("ok", "concern"):
        raise ValueError(f"unexpected verdict: {result!r}")
    return {"verdict": result["verdict"], "summary": str(result.get("summary", ""))}


if __name__ == "__main__":
    try:
        verdict = review(sys.argv[1])
    except Exception as e:  # fail closed
        verdict = {"verdict": "concern", "summary": f"AI review failed: {e}"}
    json.dump(verdict, sys.stdout)
    print()
