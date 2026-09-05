import { describe, expect, it } from 'vite-plus/test';
import { resolveAutoVersion } from '../src/rocm';

// Shape of the real listings: the apt/dnf repository stops at 7.2.4 while the
// runfile installer also ships 7.14.x and 10.0.
const PM_VERSIONS = ['6.2.4', '7.2', '7.2.4'];
const RUNFILE_VERSIONS = ['6.3.1', '7.2', '7.2.4', '7.14', '7.14.1', '10.0'];

describe('resolveAutoVersion', () => {
  it('resolves latest to the newest release across both routes', () => {
    expect(resolveAutoVersion('latest', PM_VERSIONS, RUNFILE_VERSIONS)).toEqual({
      version: '10.0',
      route: 'runfile',
    });
  });

  it('prefers the package manager when both routes offer the resolved version', () => {
    expect(resolveAutoVersion('7.2', PM_VERSIONS, RUNFILE_VERSIONS)).toEqual({
      version: '7.2.4',
      route: 'package-manager',
    });
  });

  it('falls back to the runfile route for versions only the runfile ships', () => {
    expect(resolveAutoVersion('7.14', PM_VERSIONS, RUNFILE_VERSIONS)).toEqual({
      version: '7.14.1',
      route: 'runfile',
    });
  });

  it('uses the package manager for versions only the repository ships', () => {
    expect(resolveAutoVersion('6.2', PM_VERSIONS, RUNFILE_VERSIONS)).toEqual({
      version: '6.2.4',
      route: 'package-manager',
    });
  });

  it('returns undefined when neither route offers the version', () => {
    expect(resolveAutoVersion('99.9', PM_VERSIONS, RUNFILE_VERSIONS)).toBeUndefined();
  });
});
