import copy
import unittest
from check_native_verification import CHECKS, PLATFORMS, validate

class NativeGateTest(unittest.TestCase):
    def report(self):
        return {'commit': 'abc', 'platforms': {platform: {
            'device': 'fixture', 'os_version': '1', 'build': '1', 'tester': 'tester',
            'tested_at': '2026-10-27T12:00:00Z',
            'checks': {check: {'status': 'pass', 'evidence': 'https://example.test/log'}
                       for check in CHECKS | {'remote_navigation', 'orientation'}}
        } for platform in PLATFORMS}}

    def test_complete_report(self):
        self.assertEqual(validate(self.report(), 'abc'), [])

    def test_missing_stale_pending_and_skipped_block_release(self):
        report = self.report()
        self.assertTrue(validate(report, 'def'))
        for platform in PLATFORMS:
            missing = copy.deepcopy(report)
            del missing['platforms'][platform]
            self.assertTrue(validate(missing, 'abc'))
            for status in ['pending', 'skipped', 'fail']:
                broken = copy.deepcopy(report)
                broken['platforms'][platform]['checks']['native_playback']['status'] = status
                self.assertTrue(validate(broken, 'abc'))

if __name__ == '__main__':
    unittest.main()
