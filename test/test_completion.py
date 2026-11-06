#!/usr/bin/env python3
"""Build and exercise the real Goose completion module: python3 test/test_completion.py.

Requires Goose and its C toolchain. Missing Goose is a failure, not a passing skip.
The probe uses the same native build configuration as GOSH.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = '''import std;
import os;
import completion;
import gosh_types;

fn main() {
    var input: u8[>..] = [];
    arg(1, input);
    var state = ShellState {};
    var results: u8[..256][..64] = [];
    if arg_count() > 2 {
        complete_path(input, results);
    } else {
        find_completions(state, input, results);
    }
    for result in results { print(result); }
}
'''


def main():
    goose = shutil.which("goose")
    if goose is None:
        raise SystemExit("BLOCKED: goose compiler unavailable; completion behavior was not tested")
    with tempfile.TemporaryDirectory(prefix="gosh-completion-") as temporary:
        root = Path(temporary)
        source = root / "src"
        shutil.copytree(ROOT / "src", source)
        (source / "completion_probe.goose").write_text(PROBE)
        shutil.copyfile(source / "gosh.build", source / "completion_probe.build")
        binary = root / "probe"
        subprocess.run([goose, "build", "-o", str(binary),
                        str(source / "completion_probe.goose")], check=True, cwd=root)
        work = root / "work"
        work.mkdir()
        commands = root / "commands"
        commands.mkdir()

        def fixture(directory, name, executable=False):
            path = directory / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755 if executable else 0o644)

        fixture(commands, "zzcmd_exec", True)
        fixture(commands, "zzcmd_plain")
        (commands / "zzcmd_dir").mkdir()
        fixture(work, "zzlocal_exec", True)
        fixture(work, "zzlocal_plain")
        fixture(work, "zzfile")

        def complete(line, path=None, path_only=False):
            env = dict(os.environ, PATH=str(commands) if path is None else path)
            args = [str(binary), line] + (["path-only"] if path_only else [])
            result = subprocess.run(args, cwd=work, env=env, text=True,
                                    capture_output=True, check=True, timeout=10)
            return result.stdout.splitlines()

        def expect(line, expected, **options):
            actual = complete(line, **options)
            assert sorted(actual) == sorted(expected), (line, options, actual, expected)

        for prefix in ("", "echo x | ", "echo x; ", "true && ", "false || ",
                       "sleep 1 & ", "echo x|", "true&&", "false||", "sleep 1&"):
            expect(prefix + "zzcmd", ["zzcmd_exec"])
        for prefix in ("echo ", "echo x | echo ", "true && echo ",
                       "echo 'a | b' ", 'echo "a && b" ', "echo a\\|b ",
                       "echo x >&1 ", "echo x &>out "):
            expect(prefix + "zzcmd", [])
            expect(prefix + "zzf", ["zzfile"])
        # A quoted/escaped separator followed by whitespace within the same word
        # must not turn the rest of that word into a command prefix.
        for line in ("echo 'a | zzcmd", 'echo "a && zzcmd', "echo a\\;zzcmd"):
            expect(line, [])
        expect("zzcmd", ["zzcmd_exec"], path=f"{commands}:{commands}")
        for path in ("", f":{commands}", f"{commands}:", f"{commands}::{commands}"):
            expect("zzlocal", ["zzlocal_exec"], path=path, path_only=True)
        # File completion deliberately continues to offer nonexecutable files.
        expect("echo zzlocal", ["zzlocal_exec", "zzlocal_plain"])
        expect("zzlocal", ["zzlocal_exec", "zzlocal_plain"])
        print("PASS: real Goose completion regression cases")


if __name__ == "__main__":
    main()
