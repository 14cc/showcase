#!/usr/bin/env python3
"""a5 源打包检查：逐个拆开 repo/debs/*.deb，检查每个 Mach-O 的签名/权限/依赖/路径。
用法: python3 tools/audit-debs.py repo [--cert ../embedded_cert.real.h]
有任何 ✗ 时退出码为 1。"""
import sys, io, os, re, tarfile, struct, gzip, lzma, argparse

ap = argparse.ArgumentParser()
ap.add_argument("repo"); ap.add_argument("--cert")
a = ap.parse_args()
FAIL = []; WARN = []
def bad(m): FAIL.append(m); print("  ✗", m)
def warn(m): WARN.append(m); print("  ⚠", m)
def ok(m): print("  ✓", m)

def ar_members(data):
    assert data[:8] == b"!<arch>\n"; off = 8; out = {}
    while off + 60 <= len(data):
        h = data[off:off+60]; off += 60
        n = h[:16].decode().strip().rstrip("/"); sz = int(h[48:58]); out[n] = data[off:off+sz]; off += sz + (sz & 1)
    return out

def open_tar(name, blob):
    if name.endswith(".gz"): blob = gzip.decompress(blob)
    elif name.endswith(".xz") or name.endswith(".lzma"): blob = lzma.decompress(blob)
    elif name.endswith(".zst"): raise SystemExit("zstd 压缩的 deb 不支持")
    return tarfile.open(fileobj=io.BytesIO(blob))

def thin_slices(d):
    m = struct.unpack_from(">I", d, 0)[0]
    if m in (0xcafebabe, 0xcafebabf):
        n = struct.unpack_from(">I", d, 4)[0]; res = []
        for i in range(n):
            cpu, sub, off, size = struct.unpack_from(">iiII", d, 8 + i*20)
            res.append((cpu, sub & 0xff, d[off:off+size]))
        return res
    if struct.unpack_from("<I", d, 0)[0] == 0xfeedfacf:
        cpu, sub = struct.unpack_from("<ii", d, 4); return [(cpu, sub & 0xff, d)]
    return None

def parse(d):
    ncmds = struct.unpack_from("<I", d, 16)[0]; off = 32
    info = {"dylibs": [], "id": None, "minos": None, "sig": None, "rpaths": []}
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from("<II", d, off)
        if cmd in (0xc, 0x80000018, 0x8000001f, 0xd):
            no = struct.unpack_from("<I", d, off+8)[0]; nm = d[off+no:off+cs].split(b"\0")[0].decode()
            if cmd == 0xd: info["id"] = nm
            else: info["dylibs"].append(nm)
        elif cmd == 0x32:
            mo = struct.unpack_from("<I", d, off+12)[0]; info["minos"] = f"{mo>>16}.{(mo>>8)&255}"
        elif cmd == 0x25:
            mo = struct.unpack_from("<I", d, off+8)[0]; info["minos"] = f"{mo>>16}.{(mo>>8)&255}"
        elif cmd == 0x1d:
            so, ss = struct.unpack_from("<II", d, off+8); info["sig"] = d[so:so+ss]
        elif cmd == 0x8000001c:
            no = struct.unpack_from("<I", d, off+8)[0]; info["rpaths"].append(d[off+no:off+cs].split(b"\0")[0].decode())
        off += cs
    return info

def sig_info(sig):
    if not sig or struct.unpack_from(">I", sig, 0)[0] != 0xfade0cc0: return None
    cnt = struct.unpack_from(">I", sig, 8)[0]; has_cd = False; ents = None
    for i in range(cnt):
        typ, off = struct.unpack_from(">II", sig, 12 + i*8)
        mg = struct.unpack_from(">I", sig, off)[0]
        if mg == 0xfade0c02: has_cd = True
        if mg == 0xfade7171:
            ln = struct.unpack_from(">I", sig, off+4)[0]; ents = sig[off+8:off+ln].decode("utf-8", "replace")
    return {"cd": has_cd, "ents": ents}

cert_probe = None
if a.cert and os.path.exists(a.cert):
    t = open(a.cert, encoding="utf-8", errors="replace").read()
    m = re.search(r"\{([^}]*)\}", t)
    if m:
        bs = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", m.group(1)))
        if len(bs) >= 48: cert_probe = bs[16:48]

debs = sorted(f for f in os.listdir(os.path.join(a.repo, "debs")) if f.endswith(".deb"))
for deb in debs:
    print(f"\n=== {deb}")
    mem = ar_members(open(os.path.join(a.repo, "debs", deb), "rb").read())
    ctl = next(k for k in mem if k.startswith("control.tar")); dat = next(k for k in mem if k.startswith("data.tar"))
    ct = open_tar(ctl, mem[ctl]); dt = open_tar(dat, mem[dat])
    control = ct.extractfile(next(m for m in ct.getmembers() if m.name.lstrip("./") == "control")).read().decode()
    fields = dict(re.findall(r"^([A-Za-z-]+): (.*)$", control, re.M))
    arch = fields.get("Architecture"); pkg = fields.get("Package")
    roothide = arch == "iphoneos-arm64e"   # 隐根：包内路径相对隐根目录，没有 /var/jb
    rootless = arch == "iphoneos-arm64"; pre = "/var/jb" if rootless else ""
    ok(f"{pkg} {fields.get('Version')} {arch} Name={fields.get('Name')}")
    for s in ("postinst", "prerm", "postrm"):
        mm = [m for m in ct.getmembers() if m.name.lstrip("./") == s]
        if pkg.startswith("com.rostane.showcase"):
            if not mm: bad(f"缺少 {s}")
            elif not mm[0].mode & 0o111: bad(f"{s} 不可执行")
    if roothide:
        for m in ct.getmembers():
            if m.isfile() and m.name.lstrip("./") in ("postinst", "prerm", "postrm", "preinst"):
                t = ct.extractfile(m).read().decode("utf-8", "replace")
                if re.search(r"/var/jb/", t): bad(f"隐根包的 {m.name.lstrip('./')} 里还写死了 /var/jb 路径")
                if "jbroot" not in t: bad(f"隐根包的 {m.name.lstrip('./')} 没有查找隐根目录")
    files = {"/" + m.name.lstrip("./"): m for m in dt.getmembers()}
    for p, m in files.items():
        if m.uid != 0 or m.gid != 0: bad(f"{p} 属主不是 root ({m.uid}:{m.gid})"); break
    if any(p.startswith("/var/jb") for p in files) != rootless and len(files) > 3:
        bad("文件路径布局和架构不一致（rootless 应全在 /var/jb 下，rootful 不应有 /var/jb）")
    if pkg.startswith("com.rostane.showcase"):
        app = f"{pre}/Applications/Showcase.app"
        bt_helper = "CarDisplaySim" if rootless or roothide else "carplay_bt"
        svc_helper = "CarPlay Simulator" if rootless or roothide else "carplay_services"
        need = [f"{app}/Showcase", f"{app}/{bt_helper}", f"{app}/{svc_helper}", f"{app}/Info.plist",
                f"{pre}/usr/bin/BTdaemon", f"{pre}/Library/LaunchDaemons/ch.ringwald.BTstack.plist"]
        if not roothide: need.append(f"{pre}/usr/lib/libBTstack.dylib")   # 隐根版 BTstack 静态链接
        if pkg.endswith("-taurine"):
            need += ["/Library/MobileSubstrate/DynamicLibraries/BTQuiet.dylib", "/Library/MobileSubstrate/DynamicLibraries/BTQuiet.plist"]
        for n in need:
            if n not in files: bad(f"缺少文件 {n}")
        if not any(p.startswith(app) and p.endswith(".lproj") for p in files): bad("缺少多语言 .lproj")
        if not any(p.startswith(app + "/Icon") for p in files): bad("缺少图标")
        for n in (f"{app}/Showcase", f"{app}/{bt_helper}", f"{app}/{svc_helper}"):
            if n in files and (files[n].mode & 0o7777) != 0o4755: bad(f"{n} 权限是 {oct(files[n].mode & 0o7777)}，应为 4755")
        pl = f"{pre}/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
        if pl in files:
            ptxt = dt.extractfile(files[pl]).read().decode("utf-8", "replace")
            if f"{pre}/usr/bin/BTdaemon" not in ptxt: bad(f"BTstack 启动项没有指向 {pre}/usr/bin/BTdaemon")
            else: ok("BTstack 启动项路径正确")
        ip = f"{app}/Info.plist"
        if ip in files:
            itxt = dt.extractfile(files[ip]).read().decode("utf-8", "replace")
            if "@" in re.sub(r"<string>[^<]*\.[a-z]+</string>", "", itxt) and re.search(r"@[A-Z_]+@", itxt): bad("Info.plist 里还有没替换的 @版本占位符@")
        for f in ("Depiction", "SileoDepiction", "Icon"):
            if "aminerostane.com" in fields.get(f, ""): bad(f"control 的 {f} 还指向原作者域名")
    cert_found = False
    for p, m in sorted(files.items()):
        if not m.isfile(): continue
        d = dt.extractfile(m).read()
        sl = thin_slices(d)
        if not sl: continue
        tag = []; n_fail = len(FAIL)
        for cpu, sub, s in sl:
            if cpu != 0x0100000c: continue
            inf = parse(s); si = sig_info(inf["sig"])
            if not si or not si["cd"]: bad(f"{p} 没有签名（必须至少 ad-hoc 签名）")
            if sub != 2 and inf["minos"] and tuple(map(int, inf["minos"].split("."))) > (12, 0): warn(f"{p} 最低系统 {inf['minos']}")
            for dl in inf["dylibs"]:
                if dl.startswith("@rpath") and not inf["rpaths"]: bad(f"{p} 依赖 {dl}（老系统没有，会闪退）")
                if "libswift" in dl: bad(f"{p} 依赖 Swift 运行库 {dl}")
                if roothide and ("libBTstack" in dl or dl.startswith("/var/jb")): bad(f"{p} 隐根包却链接了 {dl}")
                elif "libBTstack" in dl and dl != f"{pre}/usr/lib/libBTstack.dylib": bad(f"{p} 链接的 BTstack 路径是 {dl}，应为 {pre}/usr/lib/libBTstack.dylib")
                if rootless is False and dl.startswith("/var/jb"): bad(f"{p} rootful 包却链接了 {dl}")
            if inf["id"] and p.endswith("libBTstack.dylib") and inf["id"] != f"{pre}/usr/lib/libBTstack.dylib":
                bad(f"{p} 的 install_name 是 {inf['id']}，应为 {pre}/usr/lib/libBTstack.dylib")
            if p.endswith(("/Showcase", "CarDisplaySim", "Simulator", "/carplay_bt", "/carplay_services", "/BTdaemon")):
                if not si or not si["ents"]: bad(f"{p} 签名里没有权限(entitlements)")
            ENT = {"/Showcase": "ent_app", "CarDisplaySim": "ent_bt", "/carplay_bt": "ent_bt",
                   "Simulator": "ent_svc", "/carplay_services": "ent_svc", "/BTdaemon": "ent_btdaemon"}
            src = os.path.join(os.path.dirname(os.path.abspath(a.repo)), "showcase", "source")
            for suf, ef in ENT.items():
                if p.endswith(suf) and si and si["ents"]:
                    want = set(re.findall(r"<key>([^<]+)</key>", open(os.path.join(src, ef + ".xml"), encoding="utf-8").read()))
                    have = set(re.findall(r"<key>([^<]+)</key>", si["ents"]))
                    if want - have: bad(f"{p} 缺少权限: {', '.join(sorted(want - have))}")
            tag.append(f"arm64{'e' if sub==2 else ''} minos={inf['minos']}")
            if cert_probe and cert_probe in s: cert_found = True
            if pkg.startswith("com.rostane.showcase") and p.endswith("/Showcase") and not rootless and not roothide \
                    and (b"/.installed_taurine" in s) == pkg.endswith("-taurine"):
                bad(f"{p} " + ("没有按 Taurine 方式编译（缺 SHOWCASE_TAURINE）" if pkg.endswith("-taurine") else "混进了 Taurine 代码"))
            if pkg.startswith("com.rostane.showcase") and p.endswith(("/Showcase", "Simulator")) and (b".jbroot-" in s) != roothide:
                bad(f"{p} " + ("没有按隐根方式编译（缺 SHOWCASE_ROOTHIDE）" if roothide else "混进了隐根代码"))
        if tag and len(FAIL) == n_fail: ok(f"{p}  [{', '.join(tag)}] 已签名")
    if pkg.startswith("com.rostane.showcase") and cert_probe:
        (ok("内置证书已编进程序") if cert_found else bad("程序里找不到内置证书（编译时证书没烤进去）"))

print("\n=== 源索引")
R = a.repo
rel = open(os.path.join(R, "Release"), encoding="utf-8").read() if os.path.exists(os.path.join(R, "Release")) else ""
(ok("Release: Origin/Label = a5") if "Origin: a5" in rel and "Label: a5" in rel else bad("Release 的 Origin/Label 不是 a5"))
pk = open(os.path.join(R, "Packages"), encoding="utf-8").read() if os.path.exists(os.path.join(R, "Packages")) else ""
(ok(f"Packages 收录 {pk.count('Package: ')} 个包") if pk.count("Package: ") == len(debs) else bad("Packages 条目数和 deb 数量不一致"))
for f in ("index.html", "depictions/sileo.json", "depictions/cydia.html", "CydiaIcon.png", "icons/showcase.png"):
    (ok(f"{f} 存在") if os.path.exists(os.path.join(R, f)) else bad(f"源目录缺少 {f}"))
try:
    import json; sj = json.load(open(os.path.join(R, "depictions/sileo.json"), encoding="utf-8"))
    (ok("sileo.json 格式正确，含开源声明") if "github.com/amineross/showcase" in json.dumps(sj, ensure_ascii=False) else bad("sileo.json 没有开源项目地址"))
except Exception as e: bad(f"sileo.json 解析失败: {e}")
print(f"\n结果: {len(FAIL)} 个错误, {len(WARN)} 个警告")
sys.exit(1 if FAIL else 0)
