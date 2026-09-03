import { HttpClient, type HttpClientResponse } from '@actions/http-client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vite-plus/test';
import { resolveRunfileUrl, resolveCompanionRepo, findWindowsInstaller } from '../src/rocm';
import type { LinuxDistribution } from '../src/os_arch';

// resolveRunfileUrl / resolveCompanionRepo talk to repo.radeon.com through
// @actions/http-client (HttpClient#get / #head). Both verbs are routed
// through the same URL -> response table so the test does not depend on
// which verb the implementation picks for an existence check.
type Route = { status: number; body?: string };
let routes: Record<string, Route> = {};

function fakeResponse(status: number, body = ''): HttpClientResponse {
  return {
    message: { statusCode: status },
    readBody: async () => body,
  } as unknown as HttpClientResponse;
}

// Renders entries the way an Apache-style directory index HTML page does:
// directory entries end in "/", file entries (e.g. "*.run") do not.
function apacheIndex(entries: string[]): string {
  return entries.map((entry) => `<a href="${entry}">${entry}</a>`).join('\n');
}

beforeEach(() => {
  routes = {};
  vi.spyOn(HttpClient.prototype, 'get').mockImplementation(async (url: string) => {
    const route = routes[url];
    return fakeResponse(route ? route.status : 404, route?.body ?? '');
  });
  vi.spyOn(HttpClient.prototype, 'head').mockImplementation(async (url: string) => {
    const route = routes[url];
    return fakeResponse(route ? route.status : 404);
  });
});

afterEach(() => {
  vi.restoreAllMocks();
});

const RUNFILE_INDEX = 'https://repo.radeon.com/rocm/installer/rocm-runfile-installer/';

const ubuntu2404: LinuxDistribution = {
  id: 'ubuntu',
  version: '24.04',
  name: 'Ubuntu',
  idLink: 'debian',
  codename: 'noble',
};

function almaLinux(versionId: string): LinuxDistribution {
  return {
    id: 'almalinux',
    version: versionId,
    name: 'AlmaLinux',
    idLink: 'rhel fedora',
    codename: '',
  };
}

describe('resolveRunfileUrl', () => {
  it('resolves the distro-specific subdirectory form (7.2.4, Ubuntu 24.04)', async () => {
    routes[`${RUNFILE_INDEX}rocm-rel-7.2.4/`] = {
      status: 200,
      body: apacheIndex(['el8/', 'el9/', 'el10/', 'sles15/', 'ubuntu/']),
    };
    routes[`${RUNFILE_INDEX}rocm-rel-7.2.4/ubuntu/24.04/`] = {
      status: 200,
      body: apacheIndex(['rocm-installer_1.2.9.70204-62-93~24.04.run']),
    };

    const url = await resolveRunfileUrl('7.2.4', ubuntu2404);

    expect(url).toBe(
      `${RUNFILE_INDEX}rocm-rel-7.2.4/ubuntu/24.04/rocm-installer_1.2.9.70204-62-93~24.04.run`
    );
  });

  it('resolves the distro-specific subdirectory form (7.2.4, AlmaLinux 9.6 / el9)', async () => {
    routes[`${RUNFILE_INDEX}rocm-rel-7.2.4/`] = {
      status: 200,
      body: apacheIndex(['el8/', 'el9/', 'el10/', 'sles15/', 'ubuntu/']),
    };
    routes[`${RUNFILE_INDEX}rocm-rel-7.2.4/el9/`] = {
      status: 200,
      body: apacheIndex(['rocm-installer_1.2.9.70204-62-93~el9.run']),
    };

    const url = await resolveRunfileUrl('7.2.4', almaLinux('9.6'));

    expect(url).toBe(`${RUNFILE_INDEX}rocm-rel-7.2.4/el9/rocm-installer_1.2.9.70204-62-93~el9.run`);
  });

  it('resolves the single-file form directly under the release directory (7.14.1), regardless of distro', async () => {
    routes[`${RUNFILE_INDEX}rocm-rel-7.14.1/`] = {
      status: 200,
      body: apacheIndex(['rocm-installer-7.14.1-1.run']),
    };

    const ubuntuUrl = await resolveRunfileUrl('7.14.1', ubuntu2404);
    const rhelUrl = await resolveRunfileUrl('7.14.1', almaLinux('9.6'));

    expect(ubuntuUrl).toBe(`${RUNFILE_INDEX}rocm-rel-7.14.1/rocm-installer-7.14.1-1.run`);
    expect(rhelUrl).toBe(`${RUNFILE_INDEX}rocm-rel-7.14.1/rocm-installer-7.14.1-1.run`);
  });
});

describe('resolveCompanionRepo', () => {
  it('falls back to the amdgpu repo when the graphics repo does not exist (6.2.4, Debian)', async () => {
    routes['https://repo.radeon.com/graphics/6.2.4/ubuntu/'] = { status: 404 };
    routes['https://repo.radeon.com/amdgpu/6.2.4/ubuntu/'] = { status: 200 };

    const repo = await resolveCompanionRepo('6.2.4', ubuntu2404);

    expect(repo).toMatchObject({
      kind: 'amdgpu',
      url: 'https://repo.radeon.com/amdgpu/6.2.4/ubuntu',
    });
  });

  it('selects the graphics repo when it exists (7.2.4, Debian)', async () => {
    routes['https://repo.radeon.com/graphics/7.2.4/ubuntu/'] = { status: 200 };

    const repo = await resolveCompanionRepo('7.2.4', ubuntu2404);

    expect(repo).toMatchObject({
      kind: 'graphics',
      url: 'https://repo.radeon.com/graphics/7.2.4/ubuntu',
    });
  });

  it('selects the osver directory matching VERSION_ID (7.2.4, RHEL, VERSION_ID=9.6)', async () => {
    routes['https://repo.radeon.com/graphics/7.2.4/rhel/'] = {
      status: 200,
      body: apacheIndex(['8/', '8.10/', '9.4/', '9.6/', '9.7/', '10/', '10.1/']),
    };

    const repo = await resolveCompanionRepo('7.2.4', almaLinux('9.6'));

    expect(repo).toMatchObject({
      kind: 'graphics',
      url: 'https://repo.radeon.com/graphics/7.2.4/rhel/9.6/main/x86_64/',
    });
  });

  it('falls back to the largest osver in the same major when VERSION_ID is absent from the index (7.2.4, RHEL, VERSION_ID=9.5)', async () => {
    routes['https://repo.radeon.com/graphics/7.2.4/rhel/'] = {
      status: 200,
      body: apacheIndex(['8/', '8.10/', '9.4/', '9.6/', '9.7/', '10/', '10.1/']),
    };

    const repo = await resolveCompanionRepo('7.2.4', almaLinux('9.5'));

    expect(repo).toMatchObject({
      kind: 'graphics',
      url: 'https://repo.radeon.com/graphics/7.2.4/rhel/9.7/main/x86_64/',
    });
  });
});

describe('findWindowsInstaller', () => {
  it('resolves a major.minor input to the pinned patch version and its installer URL (6.4 -> 6.4.2)', () => {
    const result = findWindowsInstaller('6.4');

    expect(result).toEqual({
      version: '6.4.2',
      url: 'https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-25.Q3-Win10-Win11-For-HIP.exe',
    });
  });

  it('resolves "latest" to the newest table entry', () => {
    const result = findWindowsInstaller('latest');

    expect(result).toEqual({
      version: '7.2.0',
      url: 'https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-26.Q3-Win11-For-HIP.exe',
    });
  });

  it('returns undefined for a version absent from the table', () => {
    expect(findWindowsInstaller('99.9')).toBeUndefined();
  });
});
