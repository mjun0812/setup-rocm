import { describe, expect, it } from 'vite-plus/test';
import { resolveAutoVersion } from '../src/rocm';
import { WINDOWS_HIP_SDK_INSTALLERS } from '../src/const';

// When one route listing could not be fetched, `method: auto` only serves an exact
// Major.Minor.Patch request from the remaining listings; `latest` and partial versions
// are refused because they cannot be determined without every listing. These checks
// apply that rule to the 3-route Linux and 2-route Windows configurations with the pip
// listing missing. rocm_auto_routes.test.ts covers the same routes with every listing
// present.

describe('resolveAutoVersion with a missing listing (Linux, 3 routes)', () => {
  const routes = [
    { route: 'package-manager', versions: ['7.2.4'] },
    { route: 'runfile', versions: ['7.2.4', '10.0'] },
    { route: 'pip', versions: undefined },
  ];

  it('AC-1: installs an exact version from the remaining listings (runfile "10.0" for "10.0.0")', () => {
    expect(resolveAutoVersion('10.0.0', routes)).toEqual({ version: '10.0', route: 'runfile' });
  });

  it('AC-1: refuses latest because it depends on the missing pip listing', () => {
    expect(() => resolveAutoVersion('latest', routes)).toThrow(/pip version listing/);
  });

  it('AC-1: refuses a partial version because it depends on the missing pip listing', () => {
    expect(() => resolveAutoVersion('10', routes)).toThrow(/pip version listing/);
  });
});

describe('resolveAutoVersion with a missing listing (Windows, 2 routes)', () => {
  const routes = [
    { route: 'installer', versions: Object.keys(WINDOWS_HIP_SDK_INSTALLERS) },
    { route: 'pip', versions: undefined },
  ];

  it('AC-2: installs an exact version from the installer table', () => {
    expect(resolveAutoVersion('7.2.0', routes)).toEqual({ version: '7.2.0', route: 'installer' });
  });

  it('AC-2: refuses latest because it depends on the missing pip listing', () => {
    expect(() => resolveAutoVersion('latest', routes)).toThrow(/pip version listing/);
  });
});
