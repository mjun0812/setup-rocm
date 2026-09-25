import { afterEach, describe, expect, it, vi } from 'vite-plus/test';

// Record the commands the install routes run instead of running them.
vi.mock('@actions/core', () => ({ info: vi.fn(), warning: vi.fn(), debug: vi.fn() }));
vi.mock('@actions/exec', () => ({ exec: vi.fn(async () => 0) }));
vi.mock('@actions/tool-cache', () => ({
  downloadTool: vi.fn(async (_url: string, dest?: string) => dest ?? '/tmp/download'),
}));
vi.mock('@actions/io', () => ({ rmRF: vi.fn(async () => undefined) }));
vi.mock('fs', async (importOriginal) => ({
  ...(await importOriginal<typeof import('fs')>()),
  existsSync: vi.fn(() => true),
  writeFileSync: vi.fn(),
}));
// Running as root keeps sudo out of the command strings and writes root files directly.
vi.mock('../src/utils', () => ({ hasRootPrivileges: () => true }));
vi.mock('../src/rocm', () => ({
  resolveRunfileUrl: vi.fn(
    async () =>
      'https://repo.radeon.com/rocm/installer/rocm-runfile-installer/rocm-rel-7.1.1/ubuntu/24.04/rocm-installer_1.2.4.70101-25-38~24.04.run'
  ),
  findWindowsInstaller: vi.fn(),
  notFoundError: vi.fn(),
}));

import * as exec from '@actions/exec';
import { installPackageManager, installRunfile } from '../src/install';

const UBUNTU = {
  id: 'ubuntu',
  version: '24.04',
  name: 'Ubuntu',
  idLink: 'debian',
  codename: 'noble',
};
const RHEL = { id: 'rhel', version: '9.6', name: 'RHEL', idLink: 'fedora', codename: '' };
const GRAPHICS = {
  kind: 'graphics' as const,
  url: 'https://repo.radeon.com/graphics/7.1.1/ubuntu',
};

/** The command line and options of the first exec call whose command contains `needle` */
function execCall(needle: string): { command: string; options: Record<string, unknown> } {
  const call = vi.mocked(exec.exec).mock.calls.find(([command]) => command.includes(needle));
  if (!call) {
    throw new Error(`no exec call containing "${needle}"`);
  }
  return { command: call[0], options: (call[2] ?? {}) as Record<string, unknown> };
}

afterEach(() => {
  vi.clearAllMocks();
});

describe('package-manager route', () => {
  // rocm-hip-sdk 7.1 and 7.1.1 dropped their dependency on the HIP compiler meta-package, so
  // installing rocm-hip-sdk alone leaves no hipcc behind on those releases.
  it('installs the HIP compiler meta-package alongside rocm-hip-sdk via apt', async () => {
    await installPackageManager('7.1.1', UBUNTU, GRAPHICS);
    const { command } = execCall('apt-get install');
    expect(command).toMatch(/\brocm-hip-sdk\b/);
    expect(command).toMatch(/\brocm-hip-runtime-dev\b/);
  });

  it('installs the HIP compiler meta-package alongside rocm-hip-sdk via dnf', async () => {
    await installPackageManager('7.1.1', RHEL, GRAPHICS);
    const { command } = execCall('dnf install -y rocm-hip-sdk');
    expect(command).toMatch(/\brocm-hip-runtime-devel\b/);
  });

  it('bounds the apt install so a stalled one fails instead of holding the runner', async () => {
    await installPackageManager('7.1.1', UBUNTU, GRAPHICS);
    expect(execCall('apt-get install').command).toMatch(/\btimeout\b/);
  });

  it('bounds the dnf install so a stalled one fails instead of holding the runner', async () => {
    await installPackageManager('7.1.1', RHEL, GRAPHICS);
    expect(execCall('dnf install -y rocm-hip-sdk').command).toMatch(/\btimeout\b/);
  });
});

describe('runfile route', () => {
  // The installer asks for confirmation when it finds an existing ROCm. With stdin left open
  // and nothing to answer, the step waited until the job's own 36-hour timeout.
  it('closes stdin so an installer prompt reads EOF instead of waiting', async () => {
    await installRunfile('7.1.1', UBUNTU);
    const { options } = execCall('.run');
    expect(Buffer.isBuffer(options['input'])).toBe(true);
    expect((options['input'] as Buffer).length).toBe(0);
  });

  it('bounds the installer so a stalled one fails instead of holding the runner', async () => {
    await installRunfile('7.1.1', UBUNTU);
    expect(execCall('.run').command).toMatch(/\btimeout\b/);
  });
});
