"""Validate Mach-O layouts and append dylib loads without moving sections."""
import mmap
import struct

THIN = {b"\xcf\xfa\xed\xfe": ("<", 32), b"\xfe\xed\xfa\xcf": (">", 32),
        b"\xce\xfa\xed\xfe": ("<", 28), b"\xfe\xed\xfa\xce": (">", 28)}
FAT = {b"\xca\xfe\xba\xbe": (">", "IIIII"), b"\xbe\xba\xfe\xca": ("<", "IIIII"),
       b"\xca\xfe\xba\xbf": (">", "IIQQII"), b"\xbf\xba\xfe\xca": ("<", "IIQQII")}
DYLIB_LOADS = (0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20)


def parse(data):
    magic = data[:4]
    if magic not in THIN and magic not in FAT:
        return []
    slices = [(0, len(data), None)]
    if magic in FAT:
        endian, fmt = FAT[magic]
        if len(data) < 8:
            raise ValueError("Mach-O fat header 不完整")
        count = struct.unpack_from(endian + "I", data, 4)[0]
        step = struct.calcsize(endian + fmt)
        if not 1 <= count <= 64 or 8 + count * step > len(data):
            raise ValueError("Mach-O 架构表无效")
        slices, occupied = [], 8 + count * step
        entries = [struct.unpack_from(endian + fmt, data, 8 + i * step) for i in range(count)]
        for entry in sorted(entries, key=lambda entry: entry[2]):
            cpu, subtype, base, size, alignment = entry[:5]
            if (size < 28 or base < occupied or base + size > len(data)
                    or alignment > 30 or base % (1 << alignment)):
                raise ValueError("Mach-O slice 越界、重叠或未对齐")
            slices.append((base, size, (cpu, subtype)))
            occupied = base + size
    images = []
    for base, length, fat_arch in slices:
        magic = data[base:base + 4]
        if magic not in THIN:
            raise ValueError("Mach-O slice magic 无效")
        endian, header = THIN[magic]
        if length < header:
            raise ValueError("Mach-O header 不完整")
        _, cpu, subtype, kind, count, size, _ = struct.unpack_from(endian + "7I", data, base)
        if fat_arch and fat_arch != (cpu, subtype):
            raise ValueError("Mach-O 架构表与 slice 不匹配")
        end = base + header + size
        if end > base + length or count > size // 8:
            raise ValueError("Mach-O load commands 越界")
        pos, commands, loads, cryptids, platforms = base + header, [], [], [], []
        dependencies, rpaths = [], []
        for _ in range(count):
            if pos + 8 > end:
                raise ValueError("Mach-O load command 不完整")
            cmd, cmdsize = struct.unpack_from(endian + "II", data, pos)
            if cmdsize < 8 or cmdsize % (8 if header == 32 else 4) or pos + cmdsize > end:
                raise ValueError("Mach-O load command 长度无效")
            if cmd in (0x21, 0x2C):
                if cmdsize < (24 if cmd == 0x2C else 20):
                    raise ValueError("加密信息不完整")
                cryptids.append(struct.unpack_from(endian + "I", data, pos + 16)[0])
            if cmd == 0x32:  # LC_BUILD_VERSION
                if cmdsize < 24:
                    raise ValueError("LC_BUILD_VERSION 不完整")
                platforms.append(struct.unpack_from(endian + "I", data, pos + 8)[0])
            elif cmd in (0x24, 0x25, 0x2F, 0x30):
                if cmdsize < 16:
                    raise ValueError("LC_VERSION_MIN 不完整")
                platforms.append({0x24: 1, 0x25: 2, 0x2F: 3, 0x30: 4}[cmd])
            if cmd in DYLIB_LOADS:
                if cmdsize < 24:
                    raise ValueError("dylib load command 不完整")
                offset = struct.unpack_from(endian + "I", data, pos + 8)[0]
                if not 24 <= offset < cmdsize:
                    raise ValueError("dylib 名称偏移无效")
                name = data[pos + offset:pos + cmdsize]
                if b"\0" not in name:
                    raise ValueError("dylib 名称缺少结束符")
                name = name.split(b"\0", 1)[0].decode("utf-8")
                loads.append(name)
                dependencies.append({"path": name, "optional": cmd in (0x80000018, 0x20)})
            if cmd == 0x8000001C:  # LC_RPATH
                if cmdsize < 16:
                    raise ValueError("LC_RPATH 不完整")
                offset = struct.unpack_from(endian + "I", data, pos + 8)[0]
                if not 12 <= offset < cmdsize:
                    raise ValueError("rpath 偏移无效")
                name = data[pos + offset:pos + cmdsize]
                if b"\0" not in name:
                    raise ValueError("rpath 缺少结束符")
                rpaths.append(name.split(b"\0", 1)[0].decode("utf-8"))
            commands.append((cmd, pos, cmdsize))
            pos += cmdsize
        if pos != end:
            raise ValueError("Mach-O load commands 大小不一致")
        images.append(dict(base=base, length=length, endian=endian, header=header,
                           cpu=cpu, subtype=subtype, kind=kind, count=count, size=size,
                           end=end, commands=commands, loads=loads, cryptids=cryptids,
                           platforms=platforms, dependencies=dependencies, rpaths=rpaths))
    return images


def inspect(path):
    with path.open("rb") as stream:
        if stream.read(4) not in (*THIN, *FAT):
            return []
        with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            return parse(data)


def check_device_images(images, kind):
    if not images or any(image["cpu"] != 0x0100000C or image["header"] != 32
                         or image["endian"] != "<" or image["kind"] != kind for image in images):
        raise ValueError("注入支持 arm64/arm64e 的 64 位 iOS Mach-O（thin 或 universal）")
    if any(any(image["cryptids"]) for image in images):
        raise ValueError("程序仍加密（cryptid != 0），需要已解密输入；重签名不能解密")
    if any(platform != 2 for image in images for platform in image["platforms"]):
        raise ValueError("需要 iPhoneOS 真机二进制，不能注入 macOS、模拟器或其他平台构建")


def patch_loads(path, load_paths):
    if not load_paths or len(set(load_paths)) != len(load_paths):
        raise ValueError("注入库列表不能为空或重复")
    if any(not name.startswith("@executable_path/Frameworks/") or "\0" in name for name in load_paths):
        raise ValueError("无效的注入库加载路径")
    with path.open("r+b") as stream, mmap.mmap(stream.fileno(), 0) as data:
        images = parse(data)
        check_device_images(images, 2)
        patches = []
        for image in images:
            base, end, length = image["base"], image["end"], image["length"]
            existing = {name.rsplit("/", 1)[-1] for name in image["loads"]}
            if any(name.rsplit("/", 1)[-1] in existing for name in load_paths):
                raise ValueError("主程序已加载同名 dylib；请使用未注入该库的输入")
            boundary, text_end = base + length, None
            for cmd, pos, size in image["commands"]:
                if cmd != 0x19:
                    continue
                if size < 72:
                    raise ValueError("segment 不完整")
                offset, extent = struct.unpack_from("<QQ", data, pos + 40)
                nsects = struct.unpack_from("<I", data, pos + 64)[0]
                if size != 72 + 80 * nsects or offset + extent > length:
                    raise ValueError("segment 布局无效")
                name = data[pos + 8:pos + 24].rstrip(b"\0")
                if offset and extent:
                    boundary = min(boundary, base + offset)
                if name == b"__TEXT" and offset == 0:
                    text_end = base + extent
                for index in range(nsects):
                    section = pos + 72 + 80 * index
                    extent = struct.unpack_from("<Q", data, section + 40)[0]
                    offset = struct.unpack_from("<I", data, section + 48)[0]
                    flags = struct.unpack_from("<I", data, section + 64)[0]
                    if extent and flags & 0xFF not in (1, 0xC, 0x12):
                        if base + offset < end or offset + extent > length:
                            raise ValueError("section 布局无效")
                        boundary = min(boundary, base + offset)
            commands = bytearray()
            for name in load_paths:
                encoded = name.encode() + b"\0"
                size = (24 + len(encoded) + 7) & ~7
                commands.extend(struct.pack("<6I", 0xC, size, 24, 0, 0, 0)
                                + encoded + bytes(size - 24 - len(encoded)))
            if text_end is None or boundary == base + length or end + len(commands) > min(boundary, text_end):
                raise ValueError("Mach-O header padding 不足，未移动原有代码；请使用有足够头部空间的构建")
            if any(data[end:end + len(commands)]):
                raise ValueError("Mach-O 头部空隙有数据，拒绝覆盖")
            patches.append((image, commands))
        # Validate every slice and every library before changing any bytes.
        for image, commands in patches:
            data[image["end"]:image["end"] + len(commands)] = commands
            struct.pack_into("<II", data, image["base"] + 16,
                             image["count"] + len(load_paths), image["size"] + len(commands))
        data.flush()
    return [{"slice_offset": image["base"], "bytes_added": len(commands),
             "load_paths": load_paths} for image, commands in patches]
