import { describe, expect, it } from 'vite-plus/test';
import { resolveAutoVersion } from '../src/rocm';

// Shape of the real listings: the apt/dnf repository stops at 7.2.4 while the
// runfile installer also ships 7.14.x and 10.0.
const PM_VERSIONS = ['6.2.4', '7.2', '7.2.4'];
const RUNFILE_VERSIONS = ['6.3.1', '7.2', '7.2.4', '7.14', '7.14.1', '10.0'];
const BOTH = { packageManager: PM_VERSIONS, runfile: RUNFILE_VERSIONS };

describe('resolveAutoVersion with both listings', () => {
  it('resolves latest to the newest release across both routes', () => {
    expect(resolveAutoVersion('latest', BOTH)).toEqual({ version: '10.0', route: 'runfile' });
  });

  it('prefers the package manager when both routes offer the resolved version', () => {
    expect(resolveAutoVersion('7.2', BOTH)).toEqual({
      version: '7.2.4',
      route: 'package-manager',
    });
  });

  it('falls back to the runfile route for versions only the runfile ships', () => {
    expect(resolveAutoVersion('7.14', BOTH)).toEqual({ version: '7.14.1', route: 'runfile' });
  });

  it('uses the package manager for versions only the repository ships', () => {
    expect(resolveAutoVersion('6.2', BOTH)).toEqual({
      version: '6.2.4',
      route: 'package-manager',
    });
  });

  it('returns undefined when neither route offers the version', () => {
    expect(resolveAutoVersion('99.9', BOTH)).toBeUndefined();
  });
});

describe('resolveAutoVersion when one listing is unavailable', () => {
  const ONLY_PM = { packageManager: PM_VERSIONS };
  const ONLY_RUNFILE = { runfile: RUNFILE_VERSIONS };

  it('installs an exact version from the remaining listing', () => {
    expect(resolveAutoVersion('7.14.1', ONLY_RUNFILE)).toEqual({
      version: '7.14.1',
      route: 'runfile',
    });
    expect(resolveAutoVersion('7.2.4', ONLY_PM)).toEqual({
      version: '7.2.4',
      route: 'package-manager',
    });
  });

  it('returns undefined when the exact version is not in the remaining listing', () => {
    expect(resolveAutoVersion('6.2.4', ONLY_RUNFILE)).toBeUndefined();
  });

  it('refuses latest because it depends on both listings', () => {
    expect(() => resolveAutoVersion('latest', ONLY_PM)).toThrow(/runfile version listing/);
  });

  it('refuses partial versions because they depend on both listings', () => {
    expect(() => resolveAutoVersion('7', ONLY_PM)).toThrow(/runfile version listing/);
    expect(() => resolveAutoVersion('7.2', ONLY_RUNFILE)).toThrow(
      /package-manager version listing/
    );
  });

  it('fails when no listing is available', () => {
    expect(() => resolveAutoVersion('7.2.4', {})).toThrow(/no version listing/);
  });
});
