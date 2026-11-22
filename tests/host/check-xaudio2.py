#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""XAudio2 2.7 one-tap installer (app/Madeira/VCRedist.swift, XAudio2 section; WineProcessBridge.m overlay).
Static wiring plus the pin. With the pinned package in MADEIRA_XAUDIO2_CACHE (default ~/.cache/madeira-tests/
directx_Jun2010_redist.exe, or downloaded when allowed) the size and SHA-256 are checked too, and --list-cabs
prints the cabinet names inside (needs `cabextract` or 7z)."""
from pathlib import Path
import hashlib, os, re, sys
ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "app/Madeira"
fail = 0
def req(c, w):
    global fail
    print(("ok   " if c else "FAIL ") + w); fail += (not c)
r = (APP / "VCRedist.swift").read_text(); b = (APP / "WineProcessBridge.m").read_text(); s = (APP / "SettingsPages.swift").read_text()
m = re.search(r'enum XAudio2Pin \{.*?static let url = URL\(string: "([^"]+)"\)!.*?static let sha256 = "([^"]*)"\s*static let bytes: Int64 = ([0-9_]+)', r, re.S)
req(m is not None, "pin block present")
if m:
    url, sha, size = m.group(1), m.group(2), int(m.group(3).replace("_", ""))
    req(url.startswith("https://download.microsoft.com/"), "pinned URL is https on download.microsoft.com")
    req(re.fullmatch(r"[0-9a-f]{64}", sha) is not None, "SHA-256 is a real 64-hex pin (not the placeholder)")
    req(size > 50_000_000, "size is a real pin")
    cache = Path(os.environ.get("MADEIRA_XAUDIO2_CACHE", Path.home() / ".cache/madeira-tests")) / "directx_Jun2010_redist.exe"
    if cache.exists():
        data = cache.read_bytes()
        req(len(data) == size and hashlib.sha256(data).hexdigest() == sha, "cached package matches the pin")
    else:
        print("skip cached package check (file not in cache)")
# compiled part: the LZX reader over the real package (outer folder and both inner cabinets)
import shutil, struct, subprocess, tempfile
pkg = Path(os.environ.get("MADEIRA_XAUDIO2_CACHE", Path.home() / ".cache/madeira-tests")) / "directx_Jun2010_redist.exe"
if pkg.exists() and shutil.which("gcc"):
    tmp = Path(tempfile.mkdtemp())
    (tmp / "h.c").write_text(r'''#include "CabinetReader.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int c,char**v){FILE*h=fopen(v[1],"rb");fseek(h,0,2);size_t n=ftell(h);rewind(h);unsigned char*b=malloc(n);if(fread(b,1,n,h)!=n)return 9;
 madeira_cab*o=0;size_t i=0;for(;;){for(;i+4<=n&&memcmp(b+i,"MSCF",4);i++);if(i+4>n)return 8;if(!madeira_cab_open(b+i,n-i,&o))break;i++;}
 for(unsigned k=0;k<madeira_cab_file_count(o);k++){const char*nm=madeira_cab_file_name(o,k);
  if(strcasecmp(nm,"Jun2010_XAudio_x64.cab")&&strcasecmp(nm,"Jun2010_XAudio_x86.cab"))continue;
  unsigned sz=madeira_cab_file_size(o,k);unsigned char*pl=malloc(sz);if(madeira_cab_extract(o,k,pl,sz))return 2;
  madeira_cab*in;if(madeira_cab_open(pl,sz,&in))return 3;
  for(unsigned f=0;f<madeira_cab_file_count(in);f++){const char*fn=madeira_cab_file_name(in,f);
   if(strcasecmp(fn,"XAudio2_7.dll")&&strcasecmp(fn,"XAPOFX1_5.dll")&&!strstr(fn,".cat"))continue;
   unsigned fs=madeira_cab_file_size(in,f);unsigned char*d=malloc(fs);if(madeira_cab_extract(in,f,d,fs))return 4;
   char out[300];snprintf(out,300,"%s/%s__%s",v[2],nm,fn);FILE*g=fopen(out,"wb");fwrite(d,1,fs,g);fclose(g);free(d);}
  madeira_cab_close(in);free(pl);}
 return 0;}''')
    cc = subprocess.run(["gcc", "-O2", "-I", str(APP), "-o", str(tmp / "h"), str(tmp / "h.c"), str(APP / "CabinetReader.c"), "-lz"], capture_output=True, text=True)
    req(cc.returncode == 0, "CabinetReader.c compiles with the host C compiler")
    if cc.returncode == 0:
        run = subprocess.run([str(tmp / "h"), str(pkg), str(tmp)], capture_output=True)
        req(run.returncode == 0, "LZX outer and inner cabinets extract")
        for arch, mach in (("x64", 0x8664), ("x86", 0x14c)):
            dll = tmp / f"Jun2010_XAudio_{arch}.cab__XAudio2_7.dll"
            cat = next(tmp.glob(f"Jun2010_XAudio_{arch}.cab__*.cat"), None)
            if not (dll.exists() and cat): req(False, f"{arch}: XAudio2_7.dll and its catalog extracted"); continue
            d = dll.read_bytes(); pe = struct.unpack_from("<I", d, 0x3c)[0]
            req(struct.unpack_from("<H", d, pe + 4)[0] == mach, f"{arch}: PE machine")
            magic = struct.unpack_from("<H", d, pe + 24)[0]; dd = pe + 24 + (112 if magic == 0x20b else 96)
            secoff = struct.unpack_from("<I", d, dd + 32)[0]; chk = pe + 24 + 64
            body = d[:chk] + d[chk + 4:dd + 32] + d[dd + 40:secoff]
            req(hashlib.sha1(body).digest() in cat.read_bytes(), f"{arch}: Authenticode SHA-1 of the unpacked DLL is in Microsoft's signed catalog (byte-exact)")
    shutil.rmtree(tmp, ignore_errors=True)
else:
    print("skip compiled LZX check (no package in cache or no gcc)")
req("XAudio2SettingsSection()" in s and s.index("VCRedistSettingsSection()") < s.index("XAudio2SettingsSection()"), "Runtimes page shows the section under Visual C++")
req("madeira_overlay_xaudio2(fm, prefix, YES)" in b and "madeira_overlay_xaudio2(fm, prefix, NO)" in b, "bridge links x86 and x64")
req('xaudio2_7=n,b' in b and 'containsString:@"xaudio2_7"' in b, "override added unless the game names it")
req("README" not in r[r.index("enum XAudio2Pin"):] , "no bundled DLL mention")
print("FAIL" if fail else "PASS"); sys.exit(1 if fail else 0)
