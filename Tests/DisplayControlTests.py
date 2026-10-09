import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('control', Path(__file__).parents[1] / '工具/phonto/display-control.py')
c = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(c)
A = '00000000-0000-0000-0000-000000000001'
B = '00000000-0000-0000-0000-000000000002'


class DisplayControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        c.HOME = self.root
        c.ROOT = self.root / 'state'
        c.ROOT.mkdir()
        c.PHONTO = self.root / 'phonto'
        c.WINWAIT = self.root / 'phonto-winwait'
        c.WINWAIT.touch()
        self.video = self.root / '中文 $(unsafe) " 空格.mp4'
        self.video.touch()
        self.jobs = {}
        self.calls = []
        self.next_pid = 100
        self.fail_ready = False
        self.attached = ['Monitor A', 'Monitor B']
        self.command_patch = patch.object(c, 'command', self.command)
        self.command_patch.start()
        self.sleep_patch = patch.object(c.time, 'sleep', lambda _: None)
        self.sleep_patch.start()

    def tearDown(self):
        self.command_patch.stop()
        self.sleep_patch.stop()
        self.temp.cleanup()

    def command(self, args, timeout=8):
        self.calls.append(args)
        code, out, error = 0, '', ''
        if args[0] == '/bin/launchctl':
            verb = args[1]
            if verb == 'print':
                label = args[2].split('/')[-1]
                if label in self.jobs:
                    out = '  pid = ' + str(self.jobs[label]['pid'])
                else:
                    code, error = 113, 'Could not find service'
            elif verb == 'remove':
                self.jobs.pop(args[2], None)
            elif verb == 'submit':
                self.next_pid += 1
                self.jobs[args[3]] = {'pid': self.next_pid, 'args': args[5:]}
            elif verb == 'list':
                out = 'PID\tStatus\tLabel\n' + '\n'.join(
                    f"{job['pid']}\t0\t{label}" for label, job in self.jobs.items())
        elif args[0] == str(c.PHONTO):
            out = '\n'.join(name + '  ' + name + '  1920x1080' for name in self.attached)
        elif args[0] == str(c.WINWAIT):
            code = 1 if self.fail_ready else 0
        else:
            self.fail('unexpected subprocess ' + repr(args))
        return subprocess.CompletedProcess(args, code, out, error)

    def start(self, key=A, display='Monitor A'):
        c.main(['display', key, 'start', display, str(self.video)])

    def test_two_displays_and_same_video(self):
        self.start()
        first = dict(self.jobs)
        self.start(B, 'Monitor B')
        self.assertEqual(len(self.jobs), 2)
        self.assertTrue(all(self.jobs[key] == value for key, value in first.items()))
        self.assertTrue(c.state(A)['running'] and c.state(B)['running'])
        self.assertEqual(c.state(A)['lastPath'], str(self.video))
        self.assertEqual(c.state(B)['lastPath'], str(self.video))
        for value in self.jobs.values():
            self.assertEqual(value['args'][-1], str(self.video))
            self.assertIn('--display', value['args'])

    def test_switch_and_stop_are_scoped(self):
        self.start(); self.start(B, 'Monitor B')
        second = {key: value for key, value in self.jobs.items() if B in key}
        self.start()
        self.assertEqual(len(self.jobs), 2)
        c.main(['display', A, 'off'])
        self.assertEqual(self.jobs, second)
        self.assertFalse(c.state(A)['running'])
        self.assertTrue(c.state(B)['running'])

    def test_failed_new_window_preserves_old_and_other_screen(self):
        self.start(); self.start(B, 'Monitor B')
        original = dict(self.jobs)
        self.fail_ready = True
        with self.assertRaises(RuntimeError):
            self.start()
        self.assertEqual(self.jobs, original)
        self.assertTrue(c.state(A)['running'])

    def test_disconnected_target_preserves_existing(self):
        self.start()
        self.attached = ['Monitor A']
        original = dict(self.jobs)
        with self.assertRaises(RuntimeError):
            self.start(B, 'Monitor B')
        self.assertEqual(self.jobs, original)

    def test_legacy_retirement_does_not_kill_other_owners(self):
        self.start(B, 'Monitor B')
        self.jobs['com.local.phonto-wall'] = {'pid': 12}
        self.jobs['com.local.phonto-rotate'] = {'pid': 13}
        self.start()
        self.assertEqual(len(self.jobs), 2)
        self.assertFalse(any('pkill' in ' '.join(call) or 'killall' in call for call in self.calls))

    def test_stale_record_is_not_playing(self):
        self.start(); self.jobs.clear()
        self.assertFalse(c.state(A)['running'])

    def test_ambiguous_ownership_rejected(self):
        self.start()
        label = c.labels(A)[1]
        self.jobs[label] = {'pid': 900}
        with self.assertRaises(RuntimeError):
            c.state(A)
        c.stop(A)
        self.assertFalse(self.jobs)

    def test_invalid_uuid_and_path_are_rejected(self):
        for key in ['../../etc', 'a; echo unsafe']:
            with self.assertRaises(ValueError):
                c.main(['display', key, 'off'])
        with self.assertRaises(RuntimeError):
            c.start(A, 'Monitor A', '/missing/video.mp4')
        self.assertFalse(self.jobs)

    def test_all_stop_finds_owned_jobs_without_records(self):
        self.start(); self.start(B, 'Monitor B')
        for path in c.ROOT.glob('*.json'):
            path.unlink()
        unrelated = 'local.wallpaper.phonto.not-a-uuid.a'
        self.jobs[unrelated] = {'pid': 400}
        self.jobs['another.app'] = {'pid': 401}
        c.main(['off'])
        self.assertEqual(set(self.jobs), {unrelated, 'another.app'})

    def test_all_stop_ignores_unrelated_record_names(self):
        self.start(); self.start(B, 'Monitor B')
        (c.ROOT / 'settings.json').write_text('{}')
        c.main(['off'])
        self.assertFalse(self.jobs)
        self.assertTrue((c.ROOT / 'settings.json').is_file())

    def test_all_stop_continues_after_one_owner_fails(self):
        self.start(); self.start(B, 'Monitor B')
        blocked = c.labels(A)[0]
        original = self.command
        def command(args, timeout=8):
            if args[:2] == ['/bin/launchctl', 'remove'] and args[2] == blocked:
                return subprocess.CompletedProcess(args, 1, '', 'permission denied')
            return original(args, timeout)
        with patch.object(c, 'command', command):
            with self.assertRaisesRegex(RuntimeError, '停止视频任务失败'):
                c.main(['off'])
        self.assertEqual(set(self.jobs), {blocked})

    def test_scoped_stop_attempts_both_slots_after_failure(self):
        self.start()
        first, second = c.labels(A)
        self.jobs[second] = {'pid': 402}
        original = self.command
        def command(args, timeout=8):
            if args[:2] == ['/bin/launchctl', 'remove'] and args[2] == first:
                return subprocess.CompletedProcess(args, 1, '', 'permission denied')
            return original(args, timeout)
        with patch.object(c, 'command', command):
            with self.assertRaises(RuntimeError):
                c.stop(A)
        self.assertEqual(set(self.jobs), {first})

    def test_all_stop_still_attempts_records_if_listing_fails(self):
        self.start(); self.start(B, 'Monitor B')
        original = self.command
        def command(args, timeout=8):
            if args == ['/bin/launchctl', 'list']:
                return subprocess.CompletedProcess(args, 1, '', 'list denied')
            return original(args, timeout)
        with patch.object(c, 'command', command):
            with self.assertRaisesRegex(RuntimeError, 'list denied'):
                c.main(['off'])
        self.assertFalse(self.jobs)

    def test_all_stop_continues_when_legacy_stop_fails(self):
        self.start(); self.start(B, 'Monitor B')
        blocked = 'com.local.phonto-rotate'
        self.jobs[blocked] = {'pid': 403}
        self.jobs['com.local.phonto-wall.b'] = {'pid': 404}
        original = self.command
        def command(args, timeout=8):
            if args[:2] == ['/bin/launchctl', 'remove'] and args[2] == blocked:
                return subprocess.CompletedProcess(args, 1, '', 'permission denied')
            return original(args, timeout)
        with patch.object(c, 'command', command):
            with self.assertRaises(RuntimeError):
                c.main(['off'])
        self.assertEqual(set(self.jobs), {blocked})

    def test_scoped_off_stops_owner_when_legacy_stop_fails(self):
        self.start(); self.start(B, 'Monitor B')
        blocked = 'com.local.phonto-rotate'
        self.jobs[blocked] = {'pid': 405}
        original = self.command
        def command(args, timeout=8):
            if args[:2] == ['/bin/launchctl', 'remove'] and args[2] == blocked:
                return subprocess.CompletedProcess(args, 1, '', 'permission denied')
            return original(args, timeout)
        with patch.object(c, 'command', command):
            with self.assertRaises(RuntimeError):
                c.main(['display', A, 'off'])
        self.assertEqual(set(self.jobs), {blocked, c.labels(B)[0]})

    def test_idle_corrupt_metadata_does_not_block_playback_recovery(self):
        for invalid in [b'{', b'[]', b'null', b'0', b'"text"', b'{"path":99}', b'\xff', b'x' * 20_000]:
            with self.subTest(invalid=invalid[:30]):
                (c.ROOT / (A + '.json')).write_bytes(invalid)
                self.assertEqual(c.state(A), {'running': False, 'lastPath': None})

    def test_live_corrupt_metadata_requires_stop_then_recovers(self):
        for invalid in [b'{', b'[]', b'{"path":99}']:
            with self.subTest(invalid=invalid):
                self.start()
                path = c.ROOT / (A + '.json')
                path.write_bytes(invalid)
                with self.assertRaisesRegex(RuntimeError, '播放记录不一致'):
                    c.state(A)
                c.main(['display', A, 'off'])
                self.assertEqual(c.state(A), {'running': False, 'lastPath': None})

    def test_state_permission_failure_still_surfaces(self):
        with patch.object(c, 'record', side_effect=PermissionError('record access denied')):
            with self.assertRaisesRegex(PermissionError, 'access denied'):
                c.state(A)

    def test_record_write_failure_preserves_old_video_and_cleans_partial_file(self):
        self.start(); self.start(B, 'Monitor B')
        original_jobs = dict(self.jobs)
        original_write = Path.write_text
        temporary = c.ROOT / (A + '.tmp')
        def write(path, value, *args, **kwargs):
            if path == temporary:
                path.write_bytes(b'partial')
                raise OSError('disk full')
            return original_write(path, value, *args, **kwargs)
        with patch.object(Path, 'write_text', write):
            with self.assertRaisesRegex(OSError, 'disk full'):
                self.start()
        self.assertEqual(self.jobs, original_jobs)
        self.assertTrue(c.state(A)['running'] and c.state(B)['running'])
        self.assertFalse(temporary.exists())

    def test_record_commit_failure_preserves_old_and_other_display(self):
        self.start(); self.start(B, 'Monitor B')
        original_jobs = dict(self.jobs)
        original_replace = Path.replace
        temporary = c.ROOT / (A + '.tmp')
        def replace(path, target):
            if path == temporary:
                raise OSError('commit denied')
            return original_replace(path, target)
        with patch.object(Path, 'replace', replace):
            with self.assertRaisesRegex(OSError, 'commit denied'):
                self.start()
        self.assertEqual(self.jobs, original_jobs)
        self.assertFalse(temporary.exists())

    def test_old_retirement_failure_keeps_confirmed_new_window_and_reports_ambiguity(self):
        self.start(); self.start(B, 'Monitor B')
        old, new = c.labels(A)
        other = dict(self.jobs[c.labels(B)[0]])
        original = self.command
        def command(args, timeout=8):
            if args[:2] == ['/bin/launchctl', 'remove'] and args[2] == old:
                return subprocess.CompletedProcess(args, 1, '', 'permission denied')
            return original(args, timeout)
        with patch.object(c, 'command', command):
            with self.assertRaises(RuntimeError):
                self.start()
        self.assertIn(new, self.jobs)
        self.assertEqual(c.record(A)['label'], new)
        self.assertEqual(self.jobs[c.labels(B)[0]], other)
        with self.assertRaisesRegex(RuntimeError, '播放记录不一致'):
            c.state(A)
        c.stop(A)
        self.assertFalse(c.state(A)['running'])
        self.assertTrue(c.state(B)['running'])


if __name__ == '__main__':
    unittest.main()
