#!/usr/bin/env python3
"""IPA 包完整性校验：把「装得上、一打开就退」这类问题拦在打包阶段。

为什么需要这一步
----------------
iOS 的 dyld 在启动时按每个 Mach-O 的 LC_LOAD_DYLIB 逐个加载依赖，
少一个就直接终止，崩溃日志里长这样：

    termination: { namespace: DYLD, indicator: "Library missing",
                   reasons: ["Library not loaded: @rpath/OpenSSL.framework/OpenSSL",
                             "Referenced from: .../LCSignCore.framework/LCSignCore",
                             "Reason: tried: '.../LCSignClone.app/Frameworks/...'"] }

**这种错在构建阶段完全看不出来** —— xcodebuild 只保证「链接得上」，
不保证「打包后运行时还找得到」。而 `@rpath/` 形式的依赖恰恰是最容易漏的一类：
链接时 Xcode 从 DerivedData 里找到了，打包时却没人把它拷进 `.app/Frameworks/`。
（本项目真踩过一次：SwiftPM 的 OpenSSL 是动态框架，只声明在 LCSignCore 上，
App target 没声明 → 谁都没负责嵌入 → 装机后启动即退。）

所以这个脚本把「包里每个 Mach-O 的动态依赖都能在包内解析到实体文件」
变成一条可执行的断言。顺带检查嵌套 framework 有没有 Info.plist
（缺了它 zsign 读不到 CFBundleIdentifier，重签名会签出畸形 bundle）。

判定 `@rpath/` 时**忠于 dyld 的语义**：先按加载关系建图，再算每个镜像的
「rpath 栈」（主程序 ∪ 祖先链上各镜像 ∪ 自己），只有栈里真有某条 LC_RPATH
能拼出实体文件才算通过。不用「候选目录碰运气」那种写法 ——
否则「文件恰好在对的目录里、但没有任何 rpath 指向它」会被判成绿，
而假绿正是这个脚本要消灭的东西。

用法
----
    python3 Scripts/30_verify_bundle.py LCSignClone-unsigned.ipa
    python3 Scripts/30_verify_bundle.py a.ipa b.ipa     # 也可以一次校验多个

返回 0 表示全部通过，1 表示发现问题。
"""

import struct
import sys
import tempfile
import zipfile
from pathlib import Path

# ---- Mach-O 常量 -----------------------------------------------------------

MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC_32 = 0xFEEDFACE
MH_CIGAM_64 = 0xCFFAEDFE
MH_CIGAM_32 = 0xCEFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA

LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_LAZY_LOAD_DYLIB = 0x20
LC_RPATH = 0x8000001C
LC_ID_DYLIB = 0x0D

DYLIB_COMMANDS = {
    LC_LOAD_DYLIB: "LC_LOAD_DYLIB",
    LC_LOAD_WEAK_DYLIB: "LC_LOAD_WEAK_DYLIB",
    LC_REEXPORT_DYLIB: "LC_REEXPORT_DYLIB",
    LC_LOAD_UPWARD_DYLIB: "LC_LOAD_UPWARD_DYLIB",
    LC_LAZY_LOAD_DYLIB: "LC_LAZY_LOAD_DYLIB",
}


class MachOError(Exception):
    pass


def _read_cstring(blob, start, end):
    chunk = blob[start:end]
    return chunk.split(b"\x00", 1)[0].decode("utf-8", "replace")


def _parse_thin(blob, base=0):
    """解析一个 thin Mach-O，返回 (dependencies, rpaths, dylib_id)。"""
    magic = struct.unpack_from("<I", blob, base)[0]
    if magic in (MH_MAGIC_64, MH_MAGIC_32):
        is64 = magic == MH_MAGIC_64
    elif magic in (MH_CIGAM_64, MH_CIGAM_32):
        raise MachOError("大端 Mach-O，本项目不会产出")
    else:
        raise MachOError("不是 Mach-O（magic 0x%08x）" % magic)

    header_size = 32 if is64 else 28
    ncmds, = struct.unpack_from("<I", blob, base + 16)

    deps, rpaths = [], []
    dylib_id = None

    offset = base + header_size
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", blob, offset)
        if cmdsize < 8:
            raise MachOError("加载命令长度非法（%d）" % cmdsize)

        if cmd in DYLIB_COMMANDS or cmd == LC_ID_DYLIB:
            name_off, = struct.unpack_from("<I", blob, offset + 8)
            value = _read_cstring(blob, offset + name_off, offset + cmdsize)
            if cmd == LC_ID_DYLIB:
                dylib_id = value
            else:
                deps.append((DYLIB_COMMANDS[cmd], value))
        elif cmd == LC_RPATH:
            name_off, = struct.unpack_from("<I", blob, offset + 8)
            rpaths.append(_read_cstring(blob, offset + name_off, offset + cmdsize))

        offset += cmdsize

    return deps, rpaths, dylib_id


def parse_macho(path):
    """返回 (dependencies, rpaths, dylib_id)；不是 Mach-O 则抛 MachOError。"""
    blob = path.read_bytes()
    if len(blob) < 32:
        raise MachOError("文件太小")

    magic = struct.unpack_from("<I", blob, 0)[0]

    if magic in (FAT_MAGIC, FAT_CIGAM):
        # 通用二进制：逐切片校验，这里只取第一片（iOS 上不会出现）
        nfat, = struct.unpack_from(">I", blob, 4)
        offset, = struct.unpack_from(">I", blob, 8 + 16)
        return _parse_thin(blob, offset)

    return _parse_thin(blob)


# ---- 依赖路径解析 ----------------------------------------------------------

SYSTEM_PREFIXES = ("/usr/lib/", "/System/", "/System/Library/")


def is_system_path(value):
    return value.startswith(SYSTEM_PREFIXES)


def resolve(value, macho_path, executable_dir, rpath_pool):
    """把一个 LC_LOAD_DYLIB 的取值解析成包内的真实路径；解析不到返回 None。

    系统库直接算通过（返回一个哨兵字符串）。

    这里刻意**忠于 dyld 的语义**而不是用候选目录猜：
    `@rpath/` 只在调用方（及加载链）真的声明了对应 LC_RPATH 时才允许解析成功。
    否则会出现「文件恰好在对的目录里、但没有任何 rpath 指向它」这种假绿 ——
    而假绿正是这个脚本要消灭的东西。
    """
    if is_system_path(value):
        return "<系统库>"

    if value.startswith("@rpath/"):
        tail = value[len("@rpath/"):]
        for raw in rpath_pool:
            # rpath 自身也支持 @loader_path/@executable_path 前缀
            base = expand_prefix(raw, macho_path, executable_dir)
            if base is None:
                continue
            candidate = base / tail
            if candidate.exists():
                return str(candidate)
        return None

    if value.startswith("@loader_path/"):
        candidate = macho_path.parent / value[len("@loader_path/"):]
        return str(candidate) if candidate.exists() else None

    if value.startswith("@executable_path/"):
        candidate = executable_dir / value[len("@executable_path/"):]
        return str(candidate) if candidate.exists() else None

    # 绝对路径但不在系统前缀里 —— 打包出去一定装不上
    return str(value) if Path(value).exists() else None


def expand_prefix(raw, macho_path, executable_dir):
    """把一条 LC_RPATH 展开成绝对目录；含未知前缀则返回 None。"""
    if raw.startswith("@loader_path/"):
        return macho_path.parent / raw[len("@loader_path/"):]
    if raw.startswith("@executable_path/"):
        return executable_dir / raw[len("@executable_path/"):]
    if raw.startswith("@"):
        return None  # 其他 @xxx 前缀本项目不会出现，宁可判红也不猜
    return Path(raw)


# ---- 校验一个 IPA ----------------------------------------------------------

def verify(ipa_path):
    print("=" * 72)
    print("校验 %s" % ipa_path)
    print("=" * 72)

    problems = []

    with tempfile.TemporaryDirectory(prefix="verify-bundle-") as tmp:
        tmp = Path(tmp)

        try:
            with zipfile.ZipFile(ipa_path) as archive:
                archive.extractall(tmp)
        except zipfile.BadZipFile as error:
            print("  ✗ 不是合法的 zip：%s" % error)
            return 1

        payload = tmp / "Payload"
        if not payload.is_dir():
            print("  ✗ 归档里没有 Payload/ 目录")
            return 1

        apps = sorted(p for p in payload.iterdir() if p.suffix == ".app")
        if not apps:
            print("  ✗ Payload/ 里没有 .app")
            return 1

        for app_dir in apps:
            problems += verify_app(app_dir)

    print()
    if problems:
        print("发现 %d 个问题：" % len(problems))
        for item in problems:
            print("  ✗ %s" % item)
        return 1

    print("包完整性校验通过")
    return 0


def verify_app(app_dir):
    problems = []

    # ---- 1. 每个嵌套 framework 必须有 Info.plist ----
    for framework in sorted(app_dir.rglob("*.framework")):
        if not (framework / "Info.plist").is_file():
            problems.append(
                "%s 缺少 Info.plist（zsign 读不到 CFBundleIdentifier，"
                "重签名会签出 iOS 拒绝加载的畸形 bundle）"
                % framework.relative_to(app_dir)
            )

    # ---- 2. 收集所有 Mach-O ----
    machos = []
    for path in sorted(app_dir.rglob("*")):
        if not path.is_file():
            continue
        try:
            parse_macho(path)
        except (MachOError, OSError):
            continue
        machos.append(path)

    if not machos:
        problems.append("%s 里一个 Mach-O 都没有，包结构不对" % app_dir.name)
        return problems

    # ---- 3. 逐个解析动态依赖 ----
    main_executable = find_main_executable(app_dir, machos)
    executable_dir = main_executable.parent if main_executable else app_dir

    print("  App：%s" % app_dir.name)
    print("  Mach-O %d 个：" % len(machos))
    for path in machos:
        print("    · %s" % path.relative_to(app_dir))

    info = {}
    for path in machos:
        deps, rpaths, _dylib_id = parse_macho(path)
        info[path] = {"deps": deps, "rpaths": rpaths}

    pools = build_rpath_pools(info, main_executable, app_dir, executable_dir)

    print()
    print("  动态依赖解析：")

    for path in machos:
        relative = path.relative_to(app_dir)
        pool = pools.get(path, [])

        for kind, value in info[path]["deps"]:
            resolved = resolve(value, path, executable_dir, pool)

            if resolved is None:
                detail = ""
                if value.startswith("@rpath/"):
                    # 这种情况最常见，把「当时有哪些 rpath 可用」一并打出来，
                    # 省掉排查时再手工解析一遍加载命令的功夫
                    shown = "、".join(pool) if pool else "（无任何 LC_RPATH）"
                    detail = "；该镜像可用的 LC_RPATH：%s" % shown
                problems.append(
                    "%s 依赖 %s（%s），但包里找不到对应文件 —— "
                    "装到设备上启动时会被 dyld 直接终止%s"
                    % (relative, value, kind, detail)
                )
                print("    ✗ %-28s %s" % (relative, value))
            else:
                suffix = "" if resolved == "<系统库>" else "  →  %s" % Path(resolved).name
                print("    ✓ %-28s %s%s" % (relative, value, suffix))

    return problems


def build_rpath_pools(info, main_executable, app_dir, executable_dir):
    """算出每个镜像解析 `@rpath/` 时可用的 rpath 列表，对齐 dyld 的语义。

    dyld 的规则：加载某个 dylib 时，可用的 rpath 栈 = 主程序的 LC_RPATH
    ∪ 该镜像**祖先链上每个镜像**的 LC_RPATH ∪ 它自己的 LC_RPATH。

    这里分两步做：先用「全包 rpath 并集」这个**超集**把加载图画出来
    （只为确定谁加载谁，不判对错），再按真实祖先链算每个镜像的池子。
    直接用超集当池子会漏掉「文件在位但没人指向它」的假绿，
    所以最终判定必须用收紧后的池子。
    """
    if main_executable is None:
        return {path: [] for path in info}

    all_rpaths = [r for item in info.values() for r in item["rpaths"]]

    # --- 第一步：宽松解析，只为建图 ---
    graph = {}
    for path, item in info.items():
        targets = []
        for _kind, value in item["deps"]:
            target = _permissive_resolve(value, path, app_dir, executable_dir, all_rpaths)
            if target is not None:
                targets.append(target)
        graph[path] = targets

    # --- 第二步：反向可达，得到每个镜像的祖先集合 ---
    reverse = {path: [] for path in info}
    for source, targets in graph.items():
        for target in targets:
            if target in reverse:
                reverse[target].append(source)

    main_rpaths = list(info.get(main_executable, {}).get("rpaths", []))

    pools = {}
    for path in info:
        seen = {path}
        queue = [path]
        while queue:
            node = queue.pop()
            for parent in reverse.get(node, []):
                if parent not in seen:
                    seen.add(parent)
                    queue.append(parent)

        pool = list(main_rpaths)
        for node in seen:
            for raw in info.get(node, {}).get("rpaths", []):
                if raw not in pool:
                    pool.append(raw)
        pools[path] = pool

    return pools


def _permissive_resolve(value, macho_path, app_dir, executable_dir, all_rpaths):
    """只用于建图：宽松地把依赖映射到包内路径，允许借助任意 rpath。"""
    if is_system_path(value):
        return None  # 系统库不是包内节点

    if value.startswith("@rpath/"):
        tail = value[len("@rpath/"):]
        for raw in all_rpaths:
            base = expand_prefix(raw, macho_path, executable_dir)
            if base is not None and (base / tail).exists():
                return base / tail
        for extra in (app_dir / "Frameworks", macho_path.parent):
            if (extra / tail).exists():
                return extra / tail
        return None

    if value.startswith("@loader_path/"):
        candidate = macho_path.parent / value[len("@loader_path/"):]
        return candidate if candidate.exists() else None

    if value.startswith("@executable_path/"):
        candidate = executable_dir / value[len("@executable_path/"):]
        return candidate if candidate.exists() else None

    candidate = Path(value)
    return candidate if candidate.exists() else None


def find_main_executable(app_dir, machos):
    """按 Info.plist 里的 CFBundleExecutable 找主程序。"""
    import plistlib

    info = app_dir / "Info.plist"
    if info.is_file():
        try:
            with info.open("rb") as handle:
                data = plistlib.load(handle)
            name = data.get("CFBundleExecutable")
            if name:
                candidate = app_dir / name
                if candidate.is_file():
                    return candidate
        except Exception:
            pass

    # 兜底：跟 .app 同名的那一个
    candidate = app_dir / app_dir.stem
    if candidate.is_file():
        return candidate

    return machos[0] if machos else None


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2

    exit_code = 0
    for ipa in argv[1:]:
        path = Path(ipa)
        if not path.is_file():
            print("跳过（不存在）：%s\n" % ipa)
            continue
        if verify(path) != 0:
            exit_code = 1
        print()

    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
