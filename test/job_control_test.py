#!/usr/bin/env python3
"""Deterministic job-control regressions. No Goose needed for native tests.
Run: python3 test/job_control_test.py [--gosh /absolute/path/to/gosh]
All waits have deadlines; every spawned process is killed/reaped on failure.
"""
import argparse
import ctypes
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNNING, COMPLETED, STOPPED, CONTINUED = 0, 1, 2, 3


def until(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.005)
    raise AssertionError('timed out waiting for process handshake')


class NativeJobs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        library = Path(cls.tmp.name) / 'gosh_os.so'
        subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra',
                        '-Werror', '-shared', '-fPIC', str(ROOT / 'src/gosh_os.c'),
                        '-o', str(library)], check=True)
        cls.lib = ctypes.CDLL(str(library))
        for name in ('gosh_poll_job', 'gosh_wait_job'):
            getattr(cls.lib, name).argtypes = [ctypes.c_int32, ctypes.POINTER(ctypes.c_int32)]
        cls.lib.gosh_continue_job.argtypes = [ctypes.c_int32]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.children = []
        self.fds = []
        self.watchdog = None

    def arm_watchdog(self):
        self.watchdog = threading.Timer(5, self.kill_children)
        self.watchdog.start()

    def kill_children(self):
        for pid in self.children:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def tearDown(self):
        if self.watchdog:
            self.watchdog.cancel()
            self.watchdog.join()
        self.kill_children()
        for pid in self.children:
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        for fd in self.fds:
            os.close(fd)

    def spawn(self, group=0):
        read, write = os.pipe()
        pid = os.fork()
        if pid == 0:
            try:
                os.close(write)
                os.setpgid(0, group)
                # Commands synchronize each state transition with the parent.
                while True:
                    command = os.read(read, 1)
                    if command == b's':
                        os.kill(os.getpid(), signal.SIGSTOP)
                    elif command == b'x':
                        os._exit(7)
                    else:
                        os._exit(99)
            finally:
                os._exit(100)
        self.children.append(pid)
        os.close(read)
        self.fds.append(write)
        os.setpgid(pid, group)
        return pid, write

    def event(self, pid, expected):
        status = ctypes.c_int32(-999)
        def poll():
            event = self.lib.gosh_poll_job(pid, ctypes.byref(status))
            self.assertIn(event, (RUNNING, expected))
            return event == expected
        until(poll)
        return status.value

    def test_stop_continue_stop_exit(self):
        pid, control = self.spawn()
        status = ctypes.c_int32(-999)
        self.assertEqual(self.lib.gosh_poll_job(pid, ctypes.byref(status)), RUNNING)
        self.assertEqual(status.value, -999)
        for _ in range(2):
            os.write(control, b's')
            self.assertEqual(self.event(pid, STOPPED), 128 + signal.SIGSTOP)
            # Polling a stopped child with no new event must preserve caller state.
            self.assertEqual(self.lib.gosh_poll_job(pid, ctypes.byref(status)), RUNNING)
            self.assertEqual(status.value, -999)
            self.assertEqual(self.lib.gosh_continue_job(pid), 0)
            self.assertEqual(self.event(pid, CONTINUED), -999)
        os.write(control, b'x')
        self.assertEqual(self.event(pid, COMPLETED), 7)
        self.assertEqual(self.lib.gosh_poll_job(pid, ctypes.byref(status)), -1)
        self.children.remove(pid)  # Already reaped: never signal a reused PID.

    def test_foreground_wait_returns_on_stop(self):
        pid, control = self.spawn()
        os.write(control, b's')
        status = ctypes.c_int32()
        self.arm_watchdog()
        self.assertEqual(self.lib.gosh_wait_job(pid, ctypes.byref(status)), STOPPED)
        self.assertEqual(status.value, 128 + signal.SIGSTOP)

    def test_wait_retries_interrupted_system_call(self):
        pid, control = self.spawn()
        old = signal.signal(signal.SIGUSR1, lambda *_: None)
        signal.siginterrupt(signal.SIGUSR1, True)
        def interrupt_and_release():
            os.kill(os.getpid(), signal.SIGUSR1)
            os.write(control, b'x')
        timer = threading.Timer(.05, interrupt_and_release)
        timer.start()
        self.arm_watchdog()
        try:
            status = ctypes.c_int32()
            self.assertEqual(self.lib.gosh_wait_job(pid, ctypes.byref(status)), COMPLETED)
            self.assertEqual(status.value, 7)
            self.children.remove(pid)
        finally:
            timer.join()
            signal.signal(signal.SIGUSR1, old)

    def test_group_resume_reaches_all_members(self):
        leader, first = self.spawn()
        member, second = self.spawn(leader)
        for pid, fd in ((leader, first), (member, second)):
            os.write(fd, b's')
            self.event(pid, STOPPED)
        self.assertEqual(self.lib.gosh_continue_job(leader), 0)
        for pid in (leader, member):
            self.event(pid, CONTINUED)

    def test_signal_completion(self):
        pid, _ = self.spawn()
        os.kill(pid, signal.SIGTERM)
        self.assertEqual(self.event(pid, COMPLETED), 128 + signal.SIGTERM)
        self.children.remove(pid)

    def test_non_child_is_error_not_completion(self):
        status = ctypes.c_int32(-999)
        self.assertEqual(self.lib.gosh_poll_job(os.getpid(), ctypes.byref(status)), -1)
        self.assertEqual(status.value, -999)
        self.assertEqual(self.lib.gosh_continue_job(0), -1)


class ShellJobs(unittest.TestCase):
    def test_jobs_fg_bg_and_repeated_stop(self):
        self.run_shell_case(False)

    def test_pipeline_members_survive_stop_and_resume(self):
        self.run_shell_case(True)

    def test_completed_job_removed_and_exit_status_preserved(self):
        self.run_shell_case(False, stops=1)

    def run_shell_case(self, pipeline, stops=3):
        if not GOSH:
            self.skipTest('Goose/GOSH unavailable; supply --gosh to run shell regressions')
        if not Path('/proc/self/status').exists():
            self.skipTest('shell handshake uses Linux /proc')
        # Adopt orphan workers so failure cleanup can reap them too.
        libc = ctypes.CDLL(None, use_errno=True)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)  # PR_SET_CHILD_SUBREAPER
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / 'worker'
            pids = Path(directory) / 'pids'
            helper.write_text('#!/usr/bin/env python3\n' + '''import os, signal, sys, time
from pathlib import Path
pids = Path(sys.argv[2])
if sys.argv[1] == 'child':
    with pids.open('a') as f: f.write(str(os.getpid()) + '\\n')
    for stage in range(1, 4):
        Path(str(pids) + '.' + str(os.getpid())).write_text(str(stage))
        os.kill(os.getpid(), signal.SIGSTOP)
    os._exit(7)
else:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if pids.exists() and len(pids.read_text().split()) == int(sys.argv[3]) and all(Path(str(pids) + '.' + p).exists() and Path(str(pids) + '.' + p).read_text() == sys.argv[1] and Path('/proc/' + p + '/status').read_text().split('State:')[1].lstrip().startswith('T') for p in pids.read_text().split()):
            sys.exit(0)
        time.sleep(.005)
    sys.exit(1)
'''.replace('range(1, 4)', f'range(1, {stops + 1})'))
            helper.chmod(0o755)
            command = shlex.quote(str(helper))
            path = shlex.quote(str(pids))
            # Every stop is acknowledged before jobs/fg. fg must return on the
            # second stop; bg resumes it to a third stop, then fg observes its exit.
            launch = f'{command} child {path}'
            if pipeline:
                launch += ' | ' + launch
            count = 2 if pipeline else 1
            script = (f'{launch} & {command} 1 {path} {count}; '
                      f'jobs; fg; jobs; bg; {command} 3 {path} {count}; fg')
            if stops == 1:
                script = f'{launch} & {command} 1 {path} 1; jobs; fg; echo $?; jobs'
            env = dict(os.environ, HOME=directory)  # Ignore the user's .goshrc.
            proc = subprocess.Popen([GOSH, '-c', script], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, start_new_session=True, env=env)
            try:
                out, err = proc.communicate(timeout=10)
                self.assertEqual(proc.returncode, 0 if stops == 1 else 7, (out + err).decode())
                self.assertEqual(out.count(b'Stopped'), 1 if stops == 1 else 2, out.decode())
                if stops == 1:
                    self.assertTrue(out.rstrip().endswith(b'7'), out.decode())
                    self.assertEqual(out.count(b'[1]'), 1, out.decode())
                self.assertNotIn(b'Done', out)
            finally:
                # Workers have separate groups, so clean them explicitly too.
                if pids.exists():
                    for pid in pids.read_text().split():
                        try:
                            info = Path('/proc/' + pid + '/status').read_text()
                            parent = int(info.split('PPid:')[1].split()[0])
                            if parent in (proc.pid, os.getpid()):
                                os.kill(int(pid), signal.SIGKILL)
                        except (ProcessLookupError, FileNotFoundError):
                            pass
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
                if pids.exists():
                    for pid in pids.read_text().split():
                        try:
                            os.waitpid(int(pid), 0)
                        except ChildProcessError:
                            pass
                libc.prctl(36, 0, 0, 0, 0)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--gosh')
    args, remaining = parser.parse_known_args()
    GOSH = str(Path(args.gosh).resolve()) if args.gosh else None
    # Bound the overall run as well as each native wait and shell subprocess.
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(AssertionError('test deadline')))
    signal.alarm(30)
    unittest.main(argv=[__file__] + remaining)
