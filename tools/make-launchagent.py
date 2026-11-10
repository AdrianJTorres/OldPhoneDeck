#!/usr/bin/env python3
"""Stage a native user LaunchAgent. Never installs, loads or stops a job."""
import argparse
import os
from pathlib import Path
import plistlib
import re


def generate(binary, profile, config, cwd, log, label, port):
    if not re.fullmatch(r'[A-Za-z0-9.-]+', label):
        raise ValueError('invalid launchd label')
    if not 0 < port <= 65532:
        raise ValueError('invalid port')
    for path in (binary, profile, config, cwd, log):
        if not Path(path).is_absolute():
            raise ValueError('all paths must be absolute')
    return {
        'Label': label,
        'ProgramArguments': ['/usr/bin/sandbox-exec', '-f', profile, binary,
                             '--managed-startup', '--config-dir', config, '--port', str(port)],
        'WorkingDirectory': cwd,
        'LimitLoadToSessionType': 'Aqua',
        'RunAtLoad': True,
        'KeepAlive': {'SuccessfulExit': False},
        'ThrottleInterval': 30,
        'ProcessType': 'Interactive',
        'Umask': 0o077,
        'StandardOutPath': '/dev/null',
        'StandardErrorPath': log,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'profile', 'config', 'cwd', 'output'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--label', default='local.phonedeck')
    parser.add_argument('--port', default=8045, type=int)
    args = parser.parse_args()
    output = Path(args.output).absolute()
    # An exclusive staging directory prevents overwrite of an existing operational setup.
    output.mkdir(mode=0o700)
    log = output / 'startup.stderr.log'
    fd = os.open(log, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    job = generate(args.binary, args.profile, args.config, args.cwd, str(log), args.label, args.port)
    with (output / (args.label + '.plist')).open('xb') as handle:
        plistlib.dump(job, handle)
