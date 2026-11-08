#!/usr/bin/env python3
"""Independent frame timestamps/stereo markers; explicit managed codecs only."""
import argparse
from pathlib import Path
import subprocess
import array
import math
import wave
from PIL import Image,ImageDraw


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--ffmpeg',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    if not args.ffmpeg.is_absolute() or not args.ffmpeg.is_file():p.error('Provide the absolute managed FFmpeg executable')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    marker=args.output.with_suffix('.marker-reference.wav')
    samples=array.array('h')
    for n in range(194000):
        value=round(8192*math.sin(2*math.pi*1000*n/48000)) if n%48000<2400 else 0
        samples.extend((value,value))
    with wave.open(str(marker),'wb') as audio:
        audio.setnchannels(2);audio.setsampwidth(2);audio.setframerate(48000);audio.writeframes(samples.tobytes())
    command=[str(args.ffmpeg),'-v','error','-y','-f','rawvideo','-pixel_format','rgb24','-video_size','704x448','-framerate','24','-i','pipe:0','-i',str(marker),
             '-frames:v','97','-c:v','libx264','-pix_fmt','yuv420p','-crf','18','-c:a','aac','-ar','48000','-ac','2','-movflags','+faststart',str(args.output)]
    process=subprocess.Popen(command,stdin=subprocess.PIPE)
    try:
        for n in range(97):
            im=Image.new('RGB',(704,448),(n*2%255,30,60));d=ImageDraw.Draw(im)
            d.rectangle((n*5%640,180,n*5%640+64,244),fill='white');d.text((24,24),f'frame {n:03d}  time {n/24:.6f}s',fill='white',font_size=32)
            process.stdin.write(im.tobytes())
        process.stdin.close()
        if process.wait(timeout=60):raise RuntimeError('Managed fixture encoding failed')
    finally:
        if process.poll() is None:process.kill();process.wait()
    print(str(args.output))

if __name__=='__main__':main()
