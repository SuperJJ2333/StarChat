"""Generate four-second synthetic media; never uses user recordings."""
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'apps/mobile_flutter/assets/diagnostics'
out.mkdir(parents=True, exist_ok=True)
def run(*args):
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *args], check=True)
for name, codec in [('tone.m4a', 'aac'), ('tone.aac', 'aac'), ('tone.wav', 'pcm_s16le')]:
    run('-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100:duration=4', '-c:a', codec, str(out / name))
for name, codec in [('video-h264.mp4', 'libx264'), ('video-hevc.mp4', 'libx265')]:
    options = ['-tag:v', 'hvc1', '-x265-params', 'log-level=error'] if codec == 'libx265' else []
    run('-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=24:duration=4',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100:duration=4',
        '-c:v', codec, '-pix_fmt', 'yuv420p', *options, '-c:a', 'aac',
        '-movflags', '+faststart', '-shortest', str(out / name))
print('Generated five synthetic media fixtures')
