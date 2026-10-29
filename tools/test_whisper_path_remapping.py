#!/usr/bin/env python3
"""Focused Whisper build-command fixtures; default mode never invokes compilers.

After a compiler slot is released, --compiler-check CMakeCache.txt uses those
configured compilers/26.5 SDK to preprocess C/C++/Objective-C controls and compile
small debug objects. It never links or executes a compiled fixture.
"""
import ast
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
OPTIONS = ('-ffile-prefix-map', '-fmacro-prefix-map', '-fdebug-prefix-map')
KEEP_FLAGS = '-DKEEP_IDENTIFIER=17 ' + shlex.quote('-DKEEP_LITERAL="words stay"')


class BuildFixture:
    def __init__(self, checkout_name='checkout with spaces', arch=None, host='arm64'):
        self.checkout_name = checkout_name
        self.arch, self.host = arch, host

    def __enter__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='whisper path maps ')
        self.root = Path(self.temp.name) / self.checkout_name
        self.source = self.root / '.cache/whisper-runtime/whisper.cpp-1.9.4'
        self.build = self.root / '.cache/whisper-runtime' / ('build-' + (self.host if self.arch is None else self.arch))
        self.bin = self.root / 'fake commands'
        self.bin.mkdir(parents=True)
        tools = self.root / 'tools'
        tools.mkdir()
        shutil.copyfile(REPO / 'tools/build-local-whisper.sh', tools / 'build-local-whisper.sh')
        native_tools = self.root / 'native/swift/tools'
        native_tools.mkdir(parents=True)
        shutil.copyfile(REPO / 'native/swift/tools/swift-environment.sh', native_tools / 'swift-environment.sh')
        sdk = self.root / 'SDKs/MacOSX26.5.sdk'
        sdk.mkdir(parents=True)
        self.env = dict(os.environ, PATH=str(self.bin) + ':/usr/bin:/bin:/usr/sbin:/sbin',
                        UNIAPI_SWIFT_SDK=str(sdk), UNIAPI_SWIFT_TOOLCHAIN=str(self.bin / 'swift'),
                        CFLAGS='-DENV_IDENTIFIER=31', CXXFLAGS='-DENV_IDENTIFIER=32',
                        WHISPER_FIXTURE_LOG=str(self.root / 'commands.jsonl'))
        self.env.pop('UNIAPI_NATIVE_ARCH', None)
        if self.arch is not None:
            self.env['UNIAPI_NATIVE_ARCH'] = self.arch
        self.stub('uname', 'print(' + repr(self.host) + ')')
        self.stub('swift', 'raise SystemExit("Compiler execution forbidden in fake tests")')
        self.stub('swiftc', 'raise SystemExit("Compiler execution forbidden in fake tests")')
        for name in ('cc', 'c++', 'clang', 'clang++', 'make', 'curl', 'tar', 'xcrun'):
            self.stub(name, 'raise SystemExit("Unexpected build/network command in fake tests")')
        self.stub('shasum', 'import sys;print("57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae  " + sys.argv[-1])')
        self.stub('otool', 'import sys;print(sys.argv[-1]+":\\n\\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)")')
        self.stub('lipo', '''import pathlib,struct,sys
data=pathlib.Path(sys.argv[-1]).read_bytes()
print({0x0100000c:'arm64',0x01000007:'x86_64'}[struct.unpack('<I',data[4:8])[0]])
''')
        self.stub('cmake', '''import json,os,pathlib,struct,sys
args=sys.argv[1:]
with open(os.environ['WHISPER_FIXTURE_LOG'],'a') as log: log.write(json.dumps(args)+'\\n')
if '--build' in args:
    build=pathlib.Path(args[args.index('--build')+1]);(build/'bin').mkdir(exist_ok=True)
    arch=next(line.split('=',1)[1] for line in (build/'CMakeCache.txt').read_text().splitlines() if line.startswith('CMAKE_OSX_ARCHITECTURES:STRING='))
    if os.environ.get('WHISPER_FIXTURE_WRONG_ARCH') == '1': arch='x86_64' if arch=='arm64' else 'arm64'
    payload=struct.pack('<IIIIIIII',0xfeedfacf,{'arm64':0x0100000c,'x86_64':0x01000007}[arch],3 if arch=='x86_64' else 0,2,0,0,0,0)
    if os.environ.get('WHISPER_FIXTURE_LEAK') == '1': payload += str(build).encode()
    (build/'bin/whisper-cli').write_bytes(payload)
else:
    build=pathlib.Path(args[args.index('-B')+1]);build.mkdir(exist_ok=True)
    flags=[a[2:] for a in args if a.startswith(('-DCMAKE_C_FLAGS:', '-DCMAKE_CXX_FLAGS:'))]
    arch=next(a.split('=',1)[1] for a in args if a.startswith('-DCMAKE_OSX_ARCHITECTURES='))
    flags.append('CMAKE_OSX_ARCHITECTURES:STRING='+arch)
    (build/'CMakeCache.txt').write_text('\\n'.join(flags)+'\\n')
''')
        files = {'LICENSE': b'fixture root license\n',
                 'examples/stb_vorbis.c': b'ALTERNATIVE A - MIT License\nfixture stb\n\n------------------------------------------------------------------------------',
                 'examples/miniaudio.h': b'ALTERNATIVE 2 - MIT No Attribution\nfixture mini\n*/'}
        self.source.mkdir(parents=True)
        archive = self.source.parent / 'whisper-v1.9.4.tar.gz'
        with tarfile.open(archive, 'w:gz') as output:
            for name, data in files.items():
                file = self.source / name
                file.parent.mkdir(exist_ok=True)
                file.write_bytes(data)
                member = tarfile.TarInfo('whisper.cpp-1.9.4/' + name)
                member.size = len(data)
                output.addfile(member, io.BytesIO(data))
        license_file = self.root / 'native/swift/Resources/Whisper-LICENSE.txt'
        license_file.parent.mkdir()
        license_file.write_text('fixture root license\n\n\nwhisper.cpp v1.9.4 - examples/stb_vorbis.c\n\n'
                                'ALTERNATIVE A - MIT License\nfixture stb\n\n\n'
                                'whisper.cpp v1.9.4 - examples/miniaudio.h\n\n'
                                'ALTERNATIVE 2 - MIT No Attribution\nfixture mini\n')
        return self

    def __exit__(self, *args):
        self.temp.cleanup()

    def stub(self, name, source):
        file = self.bin / name
        file.write_text('#!' + sys.executable + '\n' + source + '\n')
        file.chmod(0o700)

    def seed_cache(self, flags=KEEP_FLAGS):
        self.build.mkdir(exist_ok=True)
        (self.build / 'CMakeCache.txt').write_text('CMAKE_C_FLAGS:STRING=' + flags + '\nCMAKE_CXX_FLAGS:STRING=' + flags + '\n')

    def run(self):
        result = subprocess.run(['/bin/bash', str(self.root / 'tools/build-local-whisper.sh'), '--output',
                                 str(self.root / 'output with spaces/uniapi-whisper')],
                                cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise AssertionError(result.stderr)
        calls = [json.loads(line) for line in (self.root / 'commands.jsonl').read_text().splitlines()]
        configure, build = calls[-2:]
        if build != ['--build', str(self.build), '--target', 'whisper-cli', '-j2']:
            raise AssertionError('Build target/jobs changed')
        return {language: shlex.split(next(a.split('=', 1)[1] for a in configure
                                           if a.startswith('-DCMAKE_' + language + '_FLAGS:STRING=')))
                for language in ('C', 'CXX')}, configure


class CommandTests(unittest.TestCase):
    def test_target_architecture_controls_cache_and_portable_intel_flags(self):
        for host, selected in [('arm64', None), ('x86_64', None), ('arm64', 'x86_64'), ('x86_64', 'arm64')]:
            with self.subTest(host=host, selected=selected), BuildFixture(arch=selected, host=host) as fixture:
                fixture.seed_cache()
                flags, configure = fixture.run()
                expected = host if selected is None else selected
                self.assertIn('-DCMAKE_OSX_ARCHITECTURES=' + expected, configure)
                self.assertEqual(fixture.build.name, 'build-' + expected)
                for values in flags.values():
                    self.assertIn('-DKEEP_IDENTIFIER=17', values)
                    self.assertIn('-DKEEP_LITERAL="words stay"', values)
                    self.assertEqual('-march=x86-64' in values, expected == 'x86_64')
                    self.assertEqual('-mtune=generic' in values, expected == 'x86_64')
                features = ('SSE42', 'AVX', 'AVX2', 'AVX_VNNI', 'BMI2', 'FMA', 'F16C', 'AVX512',
                            'AVX512_VBMI', 'AVX512_VNNI', 'AVX512_BF16', 'AMX_TILE', 'AMX_INT8', 'AMX_BF16')
                for feature in features:
                    self.assertEqual('-DGGML_' + feature + '=OFF' in configure, expected == 'x86_64')
                if expected == 'x86_64':
                    repeated, _ = fixture.run()
                    self.assertEqual(flags, repeated, 'A repeated Intel configure must not accumulate baseline flags')

    def test_invalid_architecture_refuses_before_cmake_or_publication(self):
        for arch in ('', 'universal', 'arm64;x86_64', 'arm64 x86_64', 'x86_64h'):
            with self.subTest(arch=arch), BuildFixture(arch=arch) as fixture:
                with self.assertRaisesRegex(AssertionError, 'UNIAPI_NATIVE_ARCH must be arm64 or x86_64'):
                    fixture.run()
                self.assertFalse((fixture.root / 'commands.jsonl').exists())
                self.assertFalse((fixture.root / 'output with spaces/uniapi-whisper').exists())
                self.assertFalse(list(fixture.source.parent.glob('.prepare.*')))

    def test_intel_custom_cpu_flags_cannot_override_portable_baseline(self):
        for flags in ('-march=native', '-mavx2', '-arch arm64', '--target=arm64-apple-macosx14.0'):
            with self.subTest(flags=flags), BuildFixture(arch='x86_64') as fixture:
                fixture.seed_cache(flags)
                with self.assertRaisesRegex(AssertionError, 'baseline refuses custom target or CPU flags'):
                    fixture.run()
                self.assertFalse((fixture.root / 'commands.jsonl').exists())
                self.assertFalse((fixture.root / 'output with spaces/uniapi-whisper').exists())
        for language in ('C', 'CXX'):
            with self.subTest(release_language=language), BuildFixture(arch='x86_64') as fixture:
                fixture.seed_cache()
                with (fixture.build / 'CMakeCache.txt').open('a') as cache:
                    cache.write('CMAKE_' + language + '_FLAGS_RELEASE:STRING=-O3 -march=native\n')
                with self.assertRaisesRegex(AssertionError, 'baseline refuses custom target or CPU flags'):
                    fixture.run()
                self.assertFalse((fixture.root / 'commands.jsonl').exists())
                self.assertFalse((fixture.root / 'output with spaces/uniapi-whisper').exists())

    def test_wrong_linked_architecture_is_refused_without_publishing(self):
        with BuildFixture(arch='x86_64') as fixture:
            fixture.env['WHISPER_FIXTURE_WRONG_ARCH'] = '1'
            with self.assertRaisesRegex(AssertionError, 'Unexpected Whisper architecture'):
                fixture.run()
            self.assertFalse((fixture.root / 'output with spaces/uniapi-whisper').exists())
            self.assertFalse(list(fixture.source.parent.glob('.prepare.*')))

    def test_spaces_and_cached_identifiers_and_literals_survive_argv(self):
        with BuildFixture() as fixture:
            fixture.seed_cache()
            flags, configure = fixture.run()
            for values in flags.values():
                self.assertIn('-DKEEP_IDENTIFIER=17', values)
                self.assertIn('-DKEEP_LITERAL="words stay"', values)
                for option in OPTIONS:
                    for spelling in (fixture.source, fixture.source.resolve()):
                        self.assertIn(option + '=' + str(spelling) + '=whisper.cpp', values)
                    for spelling in (fixture.build, fixture.build.resolve()):
                        self.assertIn(option + '=' + str(spelling) + '=whisper-build', values)
            for unchanged in ('-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0',
                              '-DBUILD_SHARED_LIBS=OFF', '-DGGML_NATIVE=OFF', '-DGGML_METAL_EMBED_LIBRARY=ON',
                              '-DWHISPER_BUILD_TESTS=OFF', '-DWHISPER_BUILD_EXAMPLES=ON', '-DWHISPER_BUILD_SERVER=OFF'):
                self.assertIn(unchanged, configure)

    def test_initial_environment_and_repeat_configure_do_not_duplicate_maps(self):
        with BuildFixture() as fixture:
            first, _ = fixture.run()
            self.assertIn('-DENV_IDENTIFIER=31', first['C'])
            self.assertIn('-DENV_IDENTIFIER=32', first['CXX'])
            second, _ = fixture.run()
            self.assertEqual(first, second)
            for values in second.values():
                roots = {fixture.source, fixture.source.resolve(), fixture.build, fixture.build.resolve()}
                self.assertEqual(sum(v.startswith(OPTIONS) for v in values), 3 * len(roots))

    def test_stale_empty_cache_is_explicitly_reconfigured(self):
        with BuildFixture() as fixture:
            fixture.seed_cache('')
            flags, _ = fixture.run()
            for values in flags.values():
                roots = {fixture.source, fixture.source.resolve(), fixture.build, fixture.build.resolve()}
                self.assertEqual(sum(v.startswith(OPTIONS) for v in values), 3 * len(roots))
            self.assertFalse(list(fixture.source.parent.glob('.prepare.*')))

    def test_unsupported_map_roots_fail_before_cmake(self):
        for character in ('=', '$', '#', '\n'):
            with self.subTest(character=repr(character)), BuildFixture('checkout ' + character + ' unsafe') as fixture:
                # Newlines are already rejected by the SDK/toolchain selector.
                with self.assertRaises(AssertionError) as failure:
                    fixture.run()
                if character == '\n':
                    self.assertEqual(str(failure.exception), '')
                else:
                    self.assertRegex(str(failure.exception), 'prefix-map roots contain unsupported characters')
                self.assertFalse((fixture.root / 'commands.jsonl').exists())
                self.assertFalse(list(fixture.source.parent.glob('.prepare.*')))

    def test_linked_binary_with_private_path_is_not_published(self):
        with BuildFixture() as fixture:
            fixture.env['WHISPER_FIXTURE_LEAK'] = '1'
            with self.assertRaisesRegex(AssertionError, 'retains private build paths'):
                fixture.run()
            self.assertFalse((fixture.root / 'output with spaces/uniapi-whisper').exists())
            self.assertFalse(list(fixture.source.parent.glob('.prepare.*')))


def compiler_check(cache_path):
    """Explicit future slot only: real preprocessing/object bytes, no runtime."""
    cache = {}
    for line in Path(cache_path).read_text().splitlines():
        if not line.startswith(('#', '//')) and ':' in line and '=' in line:
            key, value = line.split('=', 1)
            cache[key.split(':', 1)[0]] = value
    sdk = Path(cache['CMAKE_OSX_SYSROOT'])
    if sdk.name != 'MacOSX26.5.sdk' or not sdk.is_dir():
        raise SystemExit('The configured 26.5 SDK is required')
    with BuildFixture() as fixture:
        fixture.seed_cache()
        flags, _ = fixture.run()
        header = fixture.source / 'header with spaces.h'
        header.write_text('const char *header_file = __FILE__;\n')
        for language, extension, compiler_key, flags_key in (
                ('c', 'c', 'CMAKE_C_COMPILER', 'C'),
                ('c++', 'cpp', 'CMAKE_CXX_COMPILER', 'CXX'),
                ('objective-c', 'm', 'CMAKE_C_COMPILER', 'C')):
            compiler = Path(cache[compiler_key])
            if not compiler.is_absolute() or not os.access(compiler, os.X_OK):
                raise SystemExit('A configured executable compiler is required')
            file = fixture.source / ('probe with spaces.' + extension)
            literal = str(fixture.source / 'literal stays unchanged')
            common = ('#include "header with spaces.h"\nconst char *probe_file = __FILE__;\n'
                      'const char *probe_base = __BASE_FILE__;\nint identifier__FILE__ = KEEP_IDENTIFIER;\n'
                      'const char *kept_literal = KEEP_LITERAL;\n')
            file.write_text(common + 'const char *ordinary_literal = ' + json.dumps(literal) + ';\n')
            base = [v for v in flags[flags_key] if not v.startswith(OPTIONS)]
            def invoke(extra, selected):
                run = subprocess.run([str(compiler), '-x', language, '-isysroot', str(sdk),
                                      '-mmacosx-version-min=14.0', *selected, *extra, str(file)],
                                     cwd=fixture.build, capture_output=True, text=True, timeout=20)
                if run.returncode:
                    raise AssertionError('Compiler fixture failed: ' + language + '\n' + run.stderr)
                return run.stdout
            def string_value(output, identifier):
                match = re.search(r'\*\s*' + identifier + r'\s*=\s*("(?:[^"\\]|\\.)*")\s*;', output)
                if match is None:
                    raise AssertionError('Missing compiler-expanded string: ' + identifier)
                return ast.literal_eval(match[1])
            control = invoke(['-E', '-P'], base)
            mapped = invoke(['-E', '-P'], flags[flags_key])
            for name, old, new in (('probe_file', str(file), 'whisper.cpp/' + file.name),
                                   ('probe_base', str(file), 'whisper.cpp/' + file.name),
                                   ('header_file', str(header), 'whisper.cpp/' + header.name)):
                if string_value(control, name) != old or string_value(mapped, name) != new:
                    raise AssertionError('Compiler did not remap file macro: ' + language + '/' + name)
            if string_value(mapped, 'ordinary_literal') != literal or string_value(mapped, 'kept_literal') != 'words stay':
                raise AssertionError('An ordinary literal changed')
            if re.search(r'int\s+identifier__FILE__\s*=\s*17\s*;', mapped) is None:
                raise AssertionError('Identifier or retained definition changed')
            # The intentional absolute ordinary literal is a negative control,
            # not something prefix maps promise to sanitize. Remove it only in
            # this second tiny fixture to check actual emitted debug/object data.
            file.write_text(common)
            object_file = fixture.build / ('probe.' + extension + '.o')
            invoke(['-g', '-O0', '-c', '-o', str(object_file)], flags[flags_key])
            data = object_file.read_bytes()
            if bytes(str(fixture.source), 'utf-8') in data or bytes(str(fixture.build), 'utf-8') in data:
                raise AssertionError('Absolute source/build root survived in the object')
            if b'whisper.cpp/' not in data:
                raise AssertionError('Mapped diagnostic path missing from object')
            print(language + ': real macro/literal/identifier/debug-object checks passed')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--compiler-check':
        compiler_check(sys.argv[2])
    else:
        unittest.main(verbosity=2)
