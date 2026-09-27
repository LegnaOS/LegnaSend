#!/usr/bin/env python3
"""Deterministically draw the portal-derived LegnaSend mark and native app icons.

Requires Pillow. Does not edit the website, Flutter SDK, generated Dart or build products.
The source shape follows portal.css: three 50% radii, one 5/31 radius, -12deg.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
GREEN = '#54B865'
INK = '#102C16'
PAPER = '#F5F4EE'
PATH = 'M500 160 C688 160 840 312 840 500 C840 688 688 840 500 840 L270 840 C209 840 160 791 160 730 L160 500 C160 312 312 160 500 160 Z'
LETTER = 'M410 320 H500 V585 H630 V670 H410 Z'
SVG = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000"><title>LegnaSend</title><g transform="rotate(-12 500 500)"><path fill="{GREEN}" d="{PATH}"/><path fill="{INK}" d="{LETTER}"/></g></svg>\n'''
OUTPUTS = []


def shape_points():
    points = [(500, 160)]
    def curve(a, b, c):
        start = points[-1]
        for i in range(1, 81):
            t = i / 80
            points.append(tuple((1-t)**3*start[k]+3*(1-t)**2*t*a[k]+3*(1-t)*t*t*b[k]+t**3*c[k] for k in (0, 1)))
    curve((688,160),(840,312),(840,500))
    curve((840,688),(688,840),(500,840))
    points.append((270,840))
    curve((209,840),(160,791),(160,730))
    points.append((160,500))
    curve((160,312),(312,160),(500,160))
    return points


def mark(size, *, opaque=False, mono=None, scale=1):
    factor = 4 if size <= 512 else 2
    resolution = size * factor
    result = Image.new('RGBA', (resolution,resolution), PAPER if opaque else (0,0,0,0))
    draw = ImageDraw.Draw(result)
    def coords(points):
        angle = math.radians(-12)
        return [((500+scale*((x-500)*math.cos(angle)-(y-500)*math.sin(angle)))*resolution/1000,
                 (500+scale*((x-500)*math.sin(angle)+(y-500)*math.cos(angle)))*resolution/1000) for x,y in points]
    draw.polygon(coords(shape_points()),fill=mono or GREEN)
    draw.polygon(coords([(410,320),(500,320),(500,585),(630,585),(630,670),(410,670)]),fill=(0,0,0,0) if mono else INK)
    result=result.resize((size,size),Image.Resampling.LANCZOS)
    return result.convert('RGB') if opaque else result


def save(image, relative, **kwargs):
    path=ROOT/relative;path.parent.mkdir(parents=True,exist_ok=True);image.save(path,**kwargs)
    OUTPUTS.append({'path':str(path.relative_to(ROOT)),'size':list(image.size),'mode':image.mode,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})


def generate():
    (ROOT/'support/branding/legnasend-mark.svg').write_text(SVG)
    for size in (32,128,256,512):save(mark(size),f'app/assets/img/logo-{size}.png')
    for size,color in [(32,'black'),(32,'white'),(512,'white')]:save(mark(size,mono=color),f'app/assets/img/logo-{size}-{color}.png')
    for path in ['app/assets/img/logo.ico','app/assets/packaging/logo.ico','app/windows/runner/resources/app_icon.ico']:
        save(mark(256),path,format='ICO',sizes=[(n,n) for n in (16,24,32,48,64,128,256)])
    for platform in ['ios','macos']:
        folder=Path(f'app/{platform}/Runner/Assets.xcassets/AppIcon.appiconset')
        entries=json.loads((ROOT/folder/'Contents.json').read_text())['images']
        for entry in entries:
            if 'filename' not in entry:continue
            size=round(float(entry['size'].split('x')[0])*float(entry['scale'].rstrip('x')))
            target=str(folder/entry['filename'])
            if any(item['path']==target for item in OUTPUTS):continue
            save(mark(size,opaque=platform=='ios'),target)
    save(mark(32,mono='black'),'app/macos/Runner/Assets.xcassets/StatusBarItemIcon.imageset/logo-32-black.png')
    for status,color in [('Success','#257639'),('Error','#B3261E')]:
        image=mark(1024);draw=ImageDraw.Draw(image)
        draw.ellipse((665,655,950,940),fill=color,outline=PAPER,width=24)
        if status=='Success':draw.line([(731,797),(791,851),(882,748)],fill='white',width=28)
        else:
            draw.line([(764,746),(863,848)],fill='white',width=28);draw.line([(863,746),(764,848)],fill='white',width=28)
        save(image.resize((256,256),Image.Resampling.LANCZOS),f'app/macos/Runner/Assets.xcassets/AppIconWith{status}Mark.imageset/logo-1024-mac-256.png')
    save(mark(1024),'app/macos/ShareExtension/icon.icns',format='ICNS')
    for density,scale in [('mdpi',1),('hdpi',1.5),('xhdpi',2),('xxhdpi',3),('xxxhdpi',4)]:
        base=f'app/android/app/src/main/res/mipmap-{density}'
        save(mark(round(48*scale)),f'{base}/ic_launcher.png')
        save(mark(round(108*scale),scale=.64),f'{base}/ic_launcher_foreground.png')
        save(mark(round(108*scale),mono='white',scale=.64),f'{base}/ic_launcher_monochrome.png')
        save(mark(round(108*scale),mono='white',scale=.64),f'{base}/ic_launcher_quicktile_foreground.png')
    save(mark(192),'app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png')
    # Keep the unused vector fallback consistent with the adaptive foreground.
    vector=f'''<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="1000" android:viewportHeight="1000"><group android:scaleX="0.64" android:scaleY="0.64" android:pivotX="500" android:pivotY="500" android:rotation="-12"><path android:fillColor="{GREEN}" android:pathData="{PATH}"/><path android:fillColor="{INK}" android:pathData="{LETTER}"/></group></vector>\n'''
    (ROOT/'app/android/app/src/main/res/drawable/ic_launcher_foreground.xml').write_text(vector)
    (ROOT/'app/android/app/src/main/res/values/ic_launcher_background.xml').write_text(f'<?xml version="1.0" encoding="utf-8"?>\n<resources><color name="ic_launcher_background">{PAPER}</color></resources>\n')
    for path in sorted((ROOT/'support/build/msix/content/Images').glob('*.png')):
        with Image.open(path) as original:
            width,height=original.size
        image=Image.new('RGBA',(width,height))
        glyph=mark(min(width,height),mono='white' if path.name.startswith('BadgeLogo') else None)
        image.alpha_composite(glyph,((width-glyph.width)//2,(height-glyph.height)//2))
        save(image,str(path.relative_to(ROOT)))
    # Android TV uses a landscape launcher banner, not the square launcher icon.
    banner=Image.new('RGB',(1280,720),PAPER);banner.paste(mark(560,opaque=True),(360,80))
    save(banner.resize((320,180),Image.Resampling.LANCZOS),'app/android/app/src/main/res/drawable/banner.png')
    auxiliary=[{'path':path,'sha256':hashlib.sha256((ROOT/path).read_bytes()).hexdigest()} for path in [
        'support/branding/legnasend-mark.svg',
        'app/android/app/src/main/res/drawable/ic_launcher_foreground.xml',
        'app/android/app/src/main/res/values/ic_launcher_background.xml']]
    (ROOT/'support/branding/generated-icons.json').write_text(json.dumps({'brand':'LegnaSend','color':GREEN,'source':'support/branding/legnasend-mark.svg','outputs':OUTPUTS,'auxiliary':auxiliary},indent=2)+'\n')


def check():
    manifest=json.loads((ROOT/'support/branding/generated-icons.json').read_text())
    assert (ROOT/manifest['source']).read_text()==SVG
    for item in manifest['outputs']:
        path=ROOT/item['path']; assert hashlib.sha256(path.read_bytes()).hexdigest()==item['sha256'],path
        image=Image.open(path);assert list(image.size)==item['size'],path
        if '/ios/' in str(path):assert image.mode=='RGB',path
    for item in manifest['auxiliary']:
        assert hashlib.sha256((ROOT/item['path']).read_bytes()).hexdigest()==item['sha256'],item['path']
    print(f"Verified {len(manifest['outputs'])} icon assets; iOS is opaque RGB; source and hashes match.")


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
    check() if args.check else generate()
