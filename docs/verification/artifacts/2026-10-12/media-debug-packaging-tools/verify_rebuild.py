#!/usr/bin/env python3
"""Fail-closed conventional Apktool rebuild comparison. No signing or execution.

CLI: python verify_rebuild.py BUILD_DIR
Inputs: source.apk, final.apk, decoded/, verified-decoded/,
        original-manifest.txt and rebuilt-manifest.txt (aapt dump xmltree).
Only exact, typed static field defaults and element source line numbers may differ.
Signatures, alignment, ABI, release/debug identity and device acceptance remain
separate mandatory gates. This tool never treats ZIP alignment as ELF support.
"""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import re
import sys
import zipfile

class VerificationError(ValueError):
    pass

def require(condition, message):
    if not condition:
        raise VerificationError(message)

def digest_file(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def regular(path):
    require(path.is_file(), 'Required regular file missing: '+str(path))
    require(not any(p.is_symlink() or p.is_junction() for p in (path, *path.parents)),
            'Link/reparse input rejected: '+str(path))
    return path

FIELD = re.compile(r'(?P<declaration>\.field (?P<flags>(?:[\w-]+ )*)(?P<name>[^\s:]+):(?P<type>\[*[ZBSCIJFD]|\[*L[^;\s]+;)) = (?P<literal>.+)')
ZERO_LITERALS = {'B': {'0', '0x0', '0t', '0x0t'},
                 'S': {'0', '0x0', '0s', '0x0s'},
                 'C': {'0', '0x0'}, 'I': {'0', '0x0'},
                 'J': {'0', '0x0', '0L', '0x0L'}}

def normalize_static_default(line):
    match = FIELD.fullmatch(line)
    if not match or 'static' not in match['flags'].split():
        return line
    kind, literal = match['type'], match['literal']
    if ((kind == 'Z' and literal == 'false')
            or literal in ZERO_LITERALS.get(kind, set())
            or (kind.startswith(('L', '[')) and literal == 'null')):
        return match['declaration']
    return line

def smali_tree(root):
    require(root.is_dir() and not root.is_symlink() and not root.is_junction(), 'Decoded tree missing or linked: '+str(root))
    files, descriptors, methods = {}, set(), 0
    for folder in sorted(root.iterdir()):
        if not re.fullmatch(r'smali(?:_classes(?:[2-9]|[1-9][0-9]+))?', folder.name):
            continue
        require(folder.is_dir() and not folder.is_symlink() and not folder.is_junction(), 'Invalid smali root: '+str(folder))
        for path in sorted(folder.rglob('*.smali')):
            text = regular(path).read_text(encoding='utf-8-sig')
            classes = re.findall(r'^\.class(?: [^ \r\n]+)* (L[^;\s]+;)$', text, re.MULTILINE)
            require(len(classes) == 1 and classes[0] not in descriptors, 'Missing/duplicate class descriptor: '+str(path.relative_to(root)))
            descriptors.add(classes[0])
            active = False
            normalized = []
            for line in text.splitlines():
                if line.startswith('.method '):
                    require(not active, 'Nested method: '+str(path.relative_to(root)))
                    active = True
                    methods += 1
                elif line == '.end method':
                    require(active, 'Unmatched method end: '+str(path.relative_to(root)))
                    active = False
                normalized.append(line if active else normalize_static_default(line))
            require(not active, 'Unterminated method: '+str(path.relative_to(root)))
            files[path.relative_to(root).as_posix()] = '\n'.join(normalized)
    require(files and methods, 'Decoded smali/method inventory is empty')
    return files, methods

def manifest_semantics(path):
    lines = regular(path).read_text(encoding='utf-8-sig').splitlines()
    require(lines and any(re.fullmatch(r'\s*E: manifest \(line=\d+\)', line) for line in lines), 'Missing aapt manifest tree: '+str(path))
    result = []
    for line in lines:
        require(bool(re.fullmatch(r'\s*(?:N: .+|E: [^\r\n]+ \(line=\d+\)|A: .+)', line)), 'Unrecognized aapt manifest output: '+str(path))
        if re.match(r'^\s*E: ', line):
            line = re.sub(r' \(line=\d+\)$', '', line)
        result.append(line)
    return result

def inventory(apk):
    with zipfile.ZipFile(regular(apk)) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), 'Duplicate APK ZIP entry: '+str(apk))
        for name in names:
            path = PurePosixPath(name)
            require(not path.is_absolute() and '..' not in path.parts and '\\' not in name, 'Unsafe APK ZIP entry')
        entries = {n for n in names if not n.endswith('/')}
        require({'AndroidManifest.xml', 'resources.arsc', 'classes.dex'} <= entries, 'Required APK payload missing: '+str(apk))
        require(archive.getinfo('resources.arsc').file_size > 0, 'Empty resource table: '+str(apk))
        dex = sorted(n for n in entries if re.fullmatch(r'classes(?:(?:[2-9]|[1-9][0-9]+))?\.dex', n))
        require(all(archive.getinfo(n).file_size > 0 for n in dex), 'Empty DEX entry')
        preserved = sorted(n for n in entries if n.startswith(('assets/', 'lib/')))
        require(any(n.startswith('lib/') and n.endswith('.so') for n in preserved), 'Native library payload absent')
        require(any(n.startswith('assets/') for n in preserved), 'Asset payload absent')
        def entry_digest(name):
            with archive.open(name) as stream:
                return hashlib.file_digest(stream, 'sha256').hexdigest()
        return dict(entries=len(entries),dex={n:entry_digest(n) for n in dex},
                    preserved={n:entry_digest(n) for n in preserved},
                    resources=sum(n.startswith('res/') for n in entries))

def verify(root):
    root = Path(root)
    source, source_methods = smali_tree(root/'decoded')
    final, final_methods = smali_tree(root/'verified-decoded')
    require(set(source) == set(final), 'Smali class inventory changed')
    changed = [name for name in source if source[name] != final[name]]
    require(not changed, 'Smali content changed beyond strict defaults: '+', '.join(changed[:8]))
    require(source_methods == final_methods, 'Method count changed')
    require(manifest_semantics(root/'original-manifest.txt') == manifest_semantics(root/'rebuilt-manifest.txt'), 'Manifest semantics changed')
    src, dst = inventory(root/'source.apk'), inventory(root/'final.apk')
    require(set(src['dex']) == set(dst['dex']), 'DEX inventory changed')
    expected_folders = {'smali' if name == 'classes.dex' else 'smali_'+name[:-4] for name in src['dex']}
    require({name.split('/')[0] for name in source} == expected_folders and {name.split('/')[0] for name in final} == expected_folders, 'DEX/decode folder inventory mismatch')
    require(set(src['preserved']) == set(dst['preserved']), 'Native/asset inventory changed')
    require(src['preserved'] == dst['preserved'], 'Native/asset bytes changed')
    require(src['resources'] == dst['resources'] and src['resources'] > 0, 'Resource entry count changed/empty')
    return dict(status='pass', source_apk_sha256=digest_file(root/'source.apk'), final_apk_sha256=digest_file(root/'final.apk'),
                source_class_count=len(source), final_class_count=len(final), method_count=source_methods,
                changed_smali_classes=[], source_dex=list(src['dex']), final_dex=list(dst['dex']),
                changed_dex_binary=[n for n in src['dex'] if src['dex'][n] != dst['dex'][n]],
                manifest_semantics_identical=True, native_asset_entries=len(src['preserved']),
                changed_native_assets=[], added_native_assets=[], source_entries=src['entries'], final_entries=dst['entries'],
                source_resource_entries=src['resources'], final_resource_entries=dst['resources'],
                resources_arsc_present_and_nonempty=True,
                normalization='Only typed static false/integer zero/reference null defaults and aapt element source-line positions; all other smali lines exact.',
                scope='Semantic/preserved-payload rebuild comparison only. Separate signature/alignment/ABI/ELF/device gates required.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_dir', type=Path)
    args = parser.parse_args()
    try:
        report = verify(args.build_dir)
    except (VerificationError, OSError, UnicodeError, zipfile.BadZipFile) as error:
        print(json.dumps(dict(status='fail', error=str(error)), ensure_ascii=False))
        return 1
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0

if __name__ == '__main__':
    sys.exit(main())
