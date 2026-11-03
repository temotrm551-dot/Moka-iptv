import os, re, shutil
from PIL import Image, ImageDraw, ImageFont

BG = (43, 24, 16); AMBER = (200, 116, 43); CREAM = (245, 230, 208)


def logo(d, cx, cy, s):
    r = int(s * 0.46)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=AMBER, width=int(s * 0.045))
    w = int(s * 0.075)
    pts = [(cx - s * .22, cy + s * .2), (cx - s * .22, cy - s * .2), (cx, cy + s * .03),
           (cx + s * .22, cy - s * .2), (cx + s * .22, cy + s * .2)]
    d.line(pts, fill=CREAM, width=w, joint='curve')
    for x, y in (pts[0], pts[1], pts[3], pts[4]):
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=CREAM)


def make_assets():
    os.makedirs('assets', exist_ok=True)
    im = Image.new('RGB', (1024, 1024), BG)
    logo(ImageDraw.Draw(im), 512, 512, 900)
    im.save('assets/icon.png')
    b = Image.new('RGB', (640, 360), BG)
    d = ImageDraw.Draw(b)
    logo(d, 170, 180, 260)
    f = None
    for p in ('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
              '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf'):
        try:
            f = ImageFont.truetype(p, 64)
            break
        except Exception:
            pass
    f = f or ImageFont.load_default()
    d.text((320, 130), 'MOKA', font=f, fill=CREAM)
    d.text((320, 200), 'IPTV', font=f, fill=AMBER)
    b.save('assets/banner.png')


def patch_android():
    p = 'android/app/src/main/AndroidManifest.xml'
    s = open(p, encoding='utf-8').read()
    if 'LEANBACK_LAUNCHER' in s:
        return
    extra = (
        '\n    <uses-permission android:name="android.permission.INTERNET"/>'
        '\n    <uses-permission android:name="android.permission.WAKE_LOCK"/>'
        '\n    <uses-feature android:name="android.software.leanback" android:required="false"/>'
        '\n    <uses-feature android:name="android.hardware.touchscreen" android:required="false"/>')
    s = re.sub(r'(<manifest[^>]*>)', lambda m: m.group(1) + extra, s, count=1)
    s = re.sub(r'android:label="[^"]*"', 'android:label="MOKA IPTV"', s, count=1)
    s = s.replace('<application',
                  '<application\n        android:usesCleartextTraffic="true"\n        android:banner="@drawable/banner"', 1)
    s = re.sub(r'(<category android:name="android.intent.category.LAUNCHER"\s*/>)',
               lambda m: m.group(1) + '\n                <category android:name="android.intent.category.LEANBACK_LAUNCHER"/>',
               s, count=1)
    open(p, 'w', encoding='utf-8').write(s)
    os.makedirs('android/app/src/main/res/drawable', exist_ok=True)
    shutil.copy('assets/banner.png', 'android/app/src/main/res/drawable/banner.png')


def patch_ios():
    p = 'ios/Runner/Info.plist'
    if not os.path.exists(p):
        return
    s = open(p, encoding='utf-8').read()
    for key in ('CFBundleDisplayName', 'CFBundleName'):
        s = re.sub(r'(<key>%s</key>\s*<string>)[^<]*(</string>)' % key, r'\g<1>MOKA IPTV\g<2>', s)
    if 'NSAppTransportSecurity' not in s:
        ats = ('\t<key>NSAppTransportSecurity</key>\n\t<dict>\n'
               '\t\t<key>NSAllowsArbitraryLoads</key>\n\t\t<true/>\n\t</dict>\n')
        s = re.sub(r'</dict>\s*</plist>', lambda m: ats + '</dict>\n</plist>', s, count=1)
    open(p, 'w', encoding='utf-8').write(s)


make_assets()
patch_android()
patch_ios()
print('MOKA IPTV ready')
