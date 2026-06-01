#!/usr/bin/env python3
import argparse
import shutil
import subprocess
import struct
import tempfile
import zipfile
from pathlib import Path


APK_ALL_LIST_PATH = "/api/posts/all-app-list"
IPA_APP_LIST_PATH = "/api/posts/app-list"

DEFAULT_REPLACEMENTS = [
    ("https://api.jlyapp.cn", "https://pee.jlyapp.cn"),
    ("https://stz.jlyapp.cn", "https://pee.jlyapp.cn"),
    ("api.jlyapp.cn", "pee.jlyapp.cn"),
    ("stz.jlyapp.cn", "pee.jlyapp.cn"),
]


def main():
    parser = argparse.ArgumentParser(description="Patch JLY endpoints inside cike.dylib and re-pack an IPA.")
    parser.add_argument("input_ipa", type=Path)
    parser.add_argument("output_ipa", type=Path)
    parser.add_argument("--from-host")
    parser.add_argument("--to-host")
    parser.add_argument("--workdir", type=Path)
    parser.add_argument("--search-addon", type=Path, help="Optional JLYSearchAddon.dylib to embed and load from cike.dylib.")
    parser.add_argument(
        "--keep-ipa-app-list",
        action="store_true",
        help="Only patch hosts. Do not repoint the paid video list CFString to the APK all-app-list endpoint.",
    )
    args = parser.parse_args()

    replacements = DEFAULT_REPLACEMENTS
    if args.from_host or args.to_host:
        if not args.from_host or not args.to_host:
            raise SystemExit("--from-host and --to-host must be used together")
        replacements = [(args.from_host, args.to_host)]

    for old, new in replacements:
        if len(old.encode()) != len(new.encode()):
            raise SystemExit(f"Replacement must be equal length: {old!r} -> {new!r}")

    workdir = args.workdir or Path(tempfile.mkdtemp(prefix="jly_ipa_"))
    if workdir.exists():
        shutil.rmtree(workdir)
    workdir.mkdir(parents=True)

    with zipfile.ZipFile(args.input_ipa, "r") as archive:
        archive.extractall(workdir)

    app_dir = next((workdir / "Payload").glob("*.app"))
    dylib_path = app_dir / "cike.dylib"
    data = dylib_path.read_bytes()
    total = 0
    for old, new in replacements:
        from_bytes = old.encode()
        to_bytes = new.encode()
        count = data.count(from_bytes)
        total += count
        if count:
            data = data.replace(from_bytes, to_bytes)
            print(f"Patched {count} occurrence(s): {old} -> {new}")

    if total == 0:
        raise SystemExit(f"No patchable endpoint strings found in {dylib_path}")

    if not args.keep_ipa_app_list:
        data, all_list_count = patch_all_app_list_endpoint(data)
        print(f"Patched {all_list_count} architecture slice(s): {IPA_APP_LIST_PATH} request -> {APK_ALL_LIST_PATH}")

    dylib_path.write_bytes(data)
    print(f"Patched {total} total occurrence(s) in {dylib_path}")

    if args.search_addon:
        addon_name = args.search_addon.name
        shutil.copy2(args.search_addon, app_dir / addon_name)
        inject_dylib_load_command(dylib_path, f"@executable_path/{addon_name}")
        print(f"Embedded and linked {addon_name}")

    if args.output_ipa.exists():
        args.output_ipa.unlink()
    args.output_ipa.parent.mkdir(parents=True, exist_ok=True)
    repack(workdir, args.output_ipa)
    print(f"Wrote {args.output_ipa}")


def patch_all_app_list_endpoint(data):
    patcher = MachOPatcher(data)
    return patcher.patch_cfstring(IPA_APP_LIST_PATH, APK_ALL_LIST_PATH)


def inject_dylib_load_command(macho_path, dylib_name):
    data = bytearray(macho_path.read_bytes())
    injector = MachOLoadCommandInjector(data)
    macho_path.write_bytes(injector.inject(dylib_name))


class MachOLoadCommandInjector:
    FAT_MAGIC = 0xCAFEBABE
    FAT_MAGIC_64 = 0xCAFEBABF
    MH_MAGIC_64 = 0xFEEDFACF
    LC_LOAD_DYLIB = 0xC

    def __init__(self, data):
        self.data = data

    def inject(self, dylib_name):
        payload = dylib_name.encode() + b"\0"
        cmdsize = align(24 + len(payload), 8)
        command = bytearray(cmdsize)
        struct.pack_into("<II", command, 0, self.LC_LOAD_DYLIB, cmdsize)
        struct.pack_into("<IIII", command, 8, 24, 2, 0, 0)
        command[24 : 24 + len(payload)] = payload

        for slice_offset, _ in self._slices():
            self._inject_slice(slice_offset, command)
        return bytes(self.data)

    def _slices(self):
        magic = self._u32be(0)
        if magic in (self.FAT_MAGIC, self.FAT_MAGIC_64):
            arch_count = self._u32be(4)
            for index in range(arch_count):
                arch = 8 + index * 20
                yield self._u32be(arch + 8), self._u32be(arch + 12)
            return
        yield 0, len(self.data)

    def _inject_slice(self, slice_offset, command):
        if self._u32(slice_offset) != self.MH_MAGIC_64:
            raise SystemExit("Only 64-bit Mach-O slices are supported for addon injection")

        ncmds = self._u32(slice_offset + 16)
        sizeofcmds = self._u32(slice_offset + 20)
        insert_at = slice_offset + 32 + sizeofcmds
        header_end = insert_at + len(command)
        first_section = self._first_section_fileoff(slice_offset)
        if header_end > first_section:
            raise SystemExit("Not enough Mach-O header padding for addon load command")
        if any(self.data[pos] != 0 for pos in range(insert_at, header_end)):
            raise SystemExit("Mach-O header padding is not empty")

        self.data[insert_at:header_end] = command
        self._pack_u32(slice_offset + 16, ncmds + 1)
        self._pack_u32(slice_offset + 20, sizeofcmds + len(command))

    def _first_section_fileoff(self, slice_offset):
        ncmds = self._u32(slice_offset + 16)
        command = slice_offset + 32
        first = None
        for _ in range(ncmds):
            cmd = self._u32(command)
            cmdsize = self._u32(command + 4)
            if cmd == MachOPatcher.LC_SEGMENT_64:
                nsects = self._u32(command + 64)
                section = command + 72
                for _ in range(nsects):
                    size = self._u64(section + 40)
                    fileoff = self._u32(section + 48)
                    if size and fileoff:
                        absolute = slice_offset + fileoff
                        first = absolute if first is None else min(first, absolute)
                    section += 80
            command += cmdsize
        if first is None:
            raise SystemExit("Could not locate first Mach-O section")
        return first

    def _u32(self, offset):
        return struct.unpack_from("<I", self.data, offset)[0]

    def _u32be(self, offset):
        return struct.unpack_from(">I", self.data, offset)[0]

    def _u64(self, offset):
        return struct.unpack_from("<Q", self.data, offset)[0]

    def _pack_u32(self, offset, value):
        struct.pack_into("<I", self.data, offset, value)


class MachOPatcher:
    FAT_MAGIC = 0xCAFEBABE
    FAT_MAGIC_64 = 0xCAFEBABF
    MH_MAGIC_64 = 0xFEEDFACF
    LC_SEGMENT_64 = 0x19

    def __init__(self, data):
        self.data = bytearray(data)

    def patch_cfstring(self, old_string, new_string):
        count = 0
        for fat_offset, fat_size in self._slices():
            if self._patch_slice_cfstring(fat_offset, old_string, new_string):
                count += 1
        if count == 0:
            raise SystemExit(f"No CFString endpoint found for {old_string!r}")
        return bytes(self.data), count

    def _slices(self):
        magic = self._u32be(0)
        if magic in (self.FAT_MAGIC, self.FAT_MAGIC_64):
            arch_count = self._u32be(4)
            for index in range(arch_count):
                arch = 8 + index * 20
                yield self._u32be(arch + 8), self._u32be(arch + 12)
            return
        yield 0, len(self.data)

    def _patch_slice_cfstring(self, slice_offset, old_string, new_string):
        if self._u32(slice_offset) != self.MH_MAGIC_64:
            return False

        sections, text_segment = self._sections(slice_offset)
        cfstring = self._section(sections, "__cfstring")
        if cfstring is None or text_segment is None:
            return False

        old_bytes = old_string.encode()
        new_bytes = new_string.encode() + b"\0"
        header_end = slice_offset + 32 + self._u32(slice_offset + 20)
        new_fileoff, new_vmaddr = self._write_text_string(text_segment, sections, header_end, new_bytes)
        patched = False

        start = cfstring["fileoff"]
        end = start + cfstring["size"]
        for entry in range(start, end, 32):
            raw_ptr = self._u64(entry + 16)
            old_vmaddr = self._normalize_pointer(raw_ptr)
            old_fileoff = self._vmaddr_to_fileoff(sections, old_vmaddr)
            if old_fileoff is None:
                continue
            if self._cstring_at(old_fileoff) != old_bytes:
                continue

            high_bits = raw_ptr & ~0xFFFFFFFF
            self._pack_u64(entry + 16, high_bits | new_vmaddr)
            self._pack_u64(entry + 24, len(new_string))
            patched = True

        if not patched:
            # Keep the appended string only when a CFString was successfully repointed.
            self.data[new_fileoff : new_fileoff + len(new_bytes)] = b"\0" * len(new_bytes)
        return patched

    def _sections(self, slice_offset):
        ncmds = self._u32(slice_offset + 16)
        command = slice_offset + 32
        sections = []
        text_segment = None

        for _ in range(ncmds):
            cmd = self._u32(command)
            cmdsize = self._u32(command + 4)
            if cmd == self.LC_SEGMENT_64:
                segment_name = self._name(command + 8)
                vmaddr = self._u64(command + 24)
                fileoff = self._u64(command + 40)
                filesize = self._u64(command + 48)
                nsects = self._u32(command + 64)
                segment = {
                    "name": segment_name,
                    "vmaddr": vmaddr,
                    "fileoff": slice_offset + fileoff,
                    "relative_fileoff": fileoff,
                    "filesize": filesize,
                }
                if segment_name == "__TEXT":
                    text_segment = segment

                section = command + 72
                for _ in range(nsects):
                    section_name = self._name(section)
                    section_addr = self._u64(section + 32)
                    section_size = self._u64(section + 40)
                    section_fileoff = self._u32(section + 48)
                    sections.append(
                        {
                            "name": section_name,
                            "segment": segment_name,
                            "addr": section_addr,
                            "size": section_size,
                            "fileoff": slice_offset + section_fileoff,
                            "relative_fileoff": section_fileoff,
                        },
                    )
                    section += 80
            command += cmdsize

        return sections, text_segment

    @staticmethod
    def _section(sections, name):
        return next((section for section in sections if section["name"] == name), None)

    def _write_text_string(self, text_segment, sections, header_end, string_bytes):
        start = max(text_segment["fileoff"], header_end)
        end = start + text_segment["filesize"]
        occupied = []
        for section in sections:
            if section["segment"] == text_segment["name"] and section["size"]:
                occupied.append((section["fileoff"], section["fileoff"] + section["size"]))
        occupied.sort()

        free_ranges = []
        cursor = start
        for range_start, range_end in occupied:
            if cursor < range_start:
                free_ranges.append((cursor, range_start))
            cursor = max(cursor, range_end)
        if cursor < end:
            free_ranges.append((cursor, end))

        for start, end in free_ranges:
            found = self._write_in_zero_run(start, end, string_bytes)
            if found is not None:
                run_start = found
                vmaddr = text_segment["vmaddr"] + (run_start - text_segment["fileoff"])
                return run_start, vmaddr

        raise SystemExit("No mapped __TEXT padding large enough for all-app-list endpoint")

    def _write_in_zero_run(self, start, end, string_bytes):
        run_start = None

        for pos in range(start, end):
            if self.data[pos] == 0:
                if run_start is None:
                    run_start = pos
                if pos - run_start + 1 >= len(string_bytes):
                    self.data[run_start : run_start + len(string_bytes)] = string_bytes
                    return run_start
            else:
                run_start = None

        return None

    def _vmaddr_to_fileoff(self, sections, vmaddr):
        for section in sections:
            start = section["addr"]
            end = start + section["size"]
            if start <= vmaddr < end:
                return section["fileoff"] + (vmaddr - start)
        return None

    @staticmethod
    def _normalize_pointer(value):
        return value & 0xFFFFFFFF

    def _cstring_at(self, fileoff):
        end = fileoff
        while end < len(self.data) and self.data[end] != 0:
            end += 1
        return bytes(self.data[fileoff:end])

    def _name(self, offset):
        return bytes(self.data[offset : offset + 16]).split(b"\0", 1)[0].decode("ascii", "ignore")

    def _u32(self, offset):
        return struct.unpack_from("<I", self.data, offset)[0]

    def _u32be(self, offset):
        return struct.unpack_from(">I", self.data, offset)[0]

    def _u64(self, offset):
        return struct.unpack_from("<Q", self.data, offset)[0]

    def _pack_u64(self, offset, value):
        struct.pack_into("<Q", self.data, offset, value)


def repack(workdir, output_ipa):
    if shutil.which("ditto"):
        subprocess.run(
            ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", "Payload", str(output_ipa.resolve())],
            cwd=workdir,
            check=True,
        )
        return

    with zipfile.ZipFile(output_ipa, "w", zipfile.ZIP_DEFLATED) as archive:
        payload = workdir / "Payload"
        for path in payload.rglob("*"):
            if path.is_file():
                archive.write(path, path.relative_to(workdir).as_posix())


def align(value, alignment):
    return (value + alignment - 1) & ~(alignment - 1)


if __name__ == "__main__":
    main()
