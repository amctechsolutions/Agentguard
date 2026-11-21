import os
import shutil
import subprocess
import time
from playwright.sync_api import sync_playwright

DEMO_DIR = "/Users/user/agentguard/demo"
HTML_PATH = f"file://{DEMO_DIR}/demo_app.html?hud=0"
FRAMES_DIR = f"{DEMO_DIR}/frames"
OUT_MP4 = f"{DEMO_DIR}/AgentGuard_Demo_1080p.mp4"

shutil.rmtree(FRAMES_DIR, ignore_errors=True)
os.makedirs(FRAMES_DIR, exist_ok=True)

FPS = 10
# (scene_number, duration_seconds)
TIMELINE = [
    (1, 6.0),   # Scene 1: Intro Hero
    (2, 9.0),   # Scene 2: Dashboard + Import 25 Red-Team Tests
    (3, 12.0),  # Scene 3: Run Suite -> Queued -> Running -> Failed (92%, 2 Regressions)
    (4, 12.0),  # Scene 4: Result Inspector Modal (Version-Diff Banner)
    (5, 9.0),   # Scene 5: v2.2 Fixed 100% + Outro CTA
]

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, channel="chrome")
    context = browser.new_context(viewport={"width": 1920, "height": 1080})
    page = context.new_page()
    page.goto(HTML_PATH, wait_until="networkidle")

    frame_idx = 0
    for scene_num, dur in TIMELINE:
        page.evaluate(f"window.demoAPI.goToScene({scene_num})")
        scene_start = time.monotonic()
        target_frames = int(dur * FPS)
        for i in range(target_frames):
            frame_path = os.path.join(FRAMES_DIR, f"frame_{frame_idx:04d}.png")
            page.screenshot(path=frame_path)
            frame_idx += 1
            next_tick = scene_start + ((i + 1) / FPS)
            sleep_for = next_tick - time.monotonic()
            if sleep_for > 0:
                time.sleep(sleep_for)

    context.close()
    browser.close()

print(f"Captured {frame_idx} frames.")

cmd = [
    "/Users/user/bin/ffmpeg",
    "-y",
    "-framerate",
    str(FPS),
    "-i",
    os.path.join(FRAMES_DIR, "frame_%04d.png"),
    "-c:v",
    "libx264",
    "-r",
    "30",
    "-pix_fmt",
    "yuv420p",
    "-crf",
    "18",
    "-preset",
    "medium",
    "-movflags",
    "+faststart",
    OUT_MP4,
]
subprocess.run(cmd, check=True)
shutil.rmtree(FRAMES_DIR, ignore_errors=True)
print(f"Created MP4: {OUT_MP4}")
