#!/usr/bin/env python3
"""Host check for open-links (winebrowser.exe address handed to the app).

Cuts the real block out of build/ntdll-unix/process_ios.c, puts it in a small C harness and runs it on
command lines: only a winebrowser.exe spawn with a clean http(s) address is handed over, the log never
holds the text after '?', and env.MADEIRA_OPEN_LINKS=0 hands nothing over. Also checks the app side
(WineProcessBridge.m/.h) and the catalog entry by text."""
import pathlib, re, subprocess, sys, tempfile, os

root = pathlib.Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/process_ios.c").read_text()
start = src.index("        /* A game asks Windows to open a web page (ShellExecute")
end = src.index('        static const char * const blocked_names[] = { "steamerrorreporter"')
block = src[start:end]

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include <stdint.h>
typedef unsigned short WCHAR;
typedef struct { unsigned short Length; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { UNICODE_STRING ImagePathName, CommandLine; } PARAMS;
static const char *madeira_debugstr_cmdline_us( UNICODE_STRING *u ) { return "<cmdline>"; }
static int ios_image_name_is( const WCHAR *image, int image_len, const char *name )
{
    int n = (int)strlen( name ), base = 0, k;
    if (!image || image_len <= 0) return 0;
    for (k = 0; k < image_len; k++) if (image[k] == '\\' || image[k] == '/') base = k + 1;
    if (image_len - base != n) return 0;
    for (k = 0; k < n; k++) { WCHAR c = image[base + k]; if (c >= 'A' && c <= 'Z') c += 32; if (c != (WCHAR)name[k]) return 0; }
    return 1;
}
static char logbuf[4096];
static int dprintf_( int fd, const char *f, ... ) { va_list a; va_start( a, f ); int r = vsnprintf( logbuf + strlen(logbuf), sizeof(logbuf) - strlen(logbuf), f, a ); va_end( a ); return r; }
#define dprintf dprintf_
static char handed[2048];
void wine_open_link_requested( const char *url ) { strcpy( handed, url ); }
static void w( WCHAR *d, const char *s ) { while ((*d++ = (unsigned char)*s++)); }
static int run( const char *image, const char *cmd )
{
    WCHAR im[256], cm[2048]; PARAMS pp, *params = &pp;
    w( im, image ); w( cm, cmd );
    pp.ImagePathName.Buffer = im; pp.ImagePathName.Length = (unsigned short)(strlen( image ) * 2);
    pp.CommandLine.Buffer = cm; pp.CommandLine.Length = (unsigned short)(strlen( cmd ) * 2);
    handed[0] = 0; logbuf[0] = 0;
    {
''' + block + r'''
    }
    return handed[0] != 0;
}
int main( int argc, char **argv )
{
    int bad = 0;
#define CASE(img, cmd, want, wanturl) do { int g = run( img, cmd ); \
    if (g != (want) || (want && strcmp( handed, wanturl ))) { printf( "FAIL %s | %s -> got=%d [%s]\n", img, cmd, g, handed ); bad++; } } while (0)
    CASE( "C:\\windows\\system32\\winebrowser.exe", "\"C:\\windows\\system32\\winebrowser.exe\"  \"https://www.epicgames.com/activate?userCode=ABCD\"", 1, "https://www.epicgames.com/activate?userCode=ABCD" );
    CASE( "C:\\windows\\system32\\WineBrowser.exe", "winebrowser.exe HTTP://example.com/a b", 1, "HTTP://example.com/a" );
    CASE( "C:\\windows\\system32\\winebrowser.exe", "winebrowser.exe http://example.com", 1, "http://example.com" );
    CASE( "C:\\windows\\system32\\winebrowser.exe", "winebrowser.exe steam://run/1", 0, "" );
    CASE( "C:\\windows\\system32\\winebrowser.exe", "winebrowser.exe file:///etc/passwd", 0, "" );
    CASE( "C:\\windows\\system32\\winebrowser.exe", "winebrowser.exe https://", 0, "" );
    CASE( "C:\\windows\\system32\\winebrowser.exe", "winebrowser.exe xhttps://evil.example/", 0, "" );
    CASE( "C:\\game\\notbrowser.exe", "x https://example.com/", 0, "" );
    CASE( "C:\\game\\steam.exe", "steam.exe https://example.com/", 0, "" );
    run( "C:\\windows\\system32\\winebrowser.exe", "winebrowser.exe https://www.epicgames.com/activate?userCode=SECRET1" );
    if (strstr( logbuf, "SECRET1" ) || !strstr( logbuf, "[open-link]" )) { printf( "FAIL log: %s\n", logbuf ); bad++; }
    setenv( "MADEIRA_OPEN_LINKS", "0", 1 );
    CASE( "C:\\windows\\system32\\winebrowser.exe", "winebrowser.exe https://example.com/", 0, "" );
    setenv( "MADEIRA_OPEN_LINKS", "1", 1 );
    CASE( "C:\\windows\\system32\\winebrowser.exe", "winebrowser.exe https://example.com/", 1, "https://example.com/" );
    { char longcmd[3000] = "winebrowser.exe https://example.com/"; int i = strlen( longcmd ); while (i < 1500) longcmd[i++] = 'a'; longcmd[i] = 0;
      CASE( "C:\\windows\\system32\\winebrowser.exe", longcmd, 0, "" ); }
    setenv( "MADEIRA_SPAWN_BLOCK", "foo.exe;WineBrowser", 1 );
    CASE( "C:\\windows\\system32\\winebrowser.exe", "winebrowser.exe https://example.com/", 0, "" );
    unsetenv( "MADEIRA_SPAWN_BLOCK" );
    run( "C:\\windows\\system32\\winebrowser.exe", "winebrowser.exe https://example.com/?userCode=SECRET2" );
    if (strstr( logbuf, "SECRET2" ) || strstr( logbuf, "<cmdline>" )) { printf( "FAIL log2: %s\n", logbuf ); bad++; }
    printf( bad ? "FAILED %d\n" : "ok\n", bad );
    return bad != 0;
}
'''
with tempfile.TemporaryDirectory() as d:
    c = os.path.join(d, "h.c"); exe = os.path.join(d, "h")
    open(c, "w").write(harness)
    r = subprocess.run(["cc", "-std=gnu99", "-Wall", "-Werror", "-Wno-address", "-Wno-unused-function", "-Wno-unused-variable", "-o", exe, c], capture_output=True, text=True)
    if r.returncode: print(r.stderr); sys.exit(1)
    r = subprocess.run([exe], capture_output=True, text=True); print(r.stdout, end="")
    if r.returncode: sys.exit(1)

m = (root / "app/Madeira/WineProcessBridge.m").read_text()
h = (root / "app/Madeira/WineProcessBridge.h").read_text()
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
ok = ("void wine_open_link_requested(const char *url)" in m and "void wine_open_link_requested(const char *url);" in h
      and "openURL:target" in m and "@autoreleasepool" in m and 'isEqualToString:@"https"' in m and "<UIKit/UIKit.h>" in m
      and 'key: "env.MADEIRA_OPEN_LINKS"' in cat)
print("app side + catalog:", "ok" if ok else "FAIL")
sys.exit(0 if ok else 1)
