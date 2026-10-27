#!/usr/bin/env python3
"""Block publication unless every native target has evidence for this commit."""
import argparse
import json
from pathlib import Path

PLATFORMS = {'android', 'android-tv', 'ios', 'linux', 'macos', 'windows'}
CHECKS = {'sign_in_callback', 'source_loading', 'native_playback', 'quality_switch',
          'audio_subtitles', 'resume', 'offline_playback', 'download_storage',
          'unavailable_actions', 'next_episode', 'search_retry'}


def validate(report, commit):
    errors = []
    if report.get('commit') != commit:
        errors.append('Evidence must match the exact release commit')
    results = report.get('platforms', {})
    for platform in sorted(PLATFORMS):
        record = results.get(platform, {})
        for field in ['device', 'os_version', 'build', 'tester', 'tested_at']:
            if not isinstance(record.get(field), str) or not record[field].strip():
                errors.append(f'{platform}: missing {field}')
        required = CHECKS | ({'remote_navigation'} if platform == 'android-tv' else set())
        required |= {'orientation'} if platform in {'android', 'ios'} else set()
        for check in sorted(required):
            outcome = record.get('checks', {}).get(check, {})
            if outcome.get('status') != 'pass':
                errors.append(f'{platform}/{check}: not passed (missing, skipped and pending block release)')
            evidence = outcome.get('evidence', '')
            if not isinstance(evidence, str) or not evidence.startswith('https://'):
                errors.append(f'{platform}/{check}: missing evidence URL')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    errors = validate(json.loads(args.report.read_text()), args.commit)
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'Native verification passed for all six targets at {args.commit}')


if __name__ == '__main__':
    main()
