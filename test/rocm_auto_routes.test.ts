import { describe, expect, it } from 'vite-plus/test';
import { resolveAutoVersion } from '../src/rocm';
import { WINDOWS_HIP_SDK_INSTALLERS } from '../src/const';

// Checks for the generalized resolveAutoVersion(input, routes) seam (design.md
// "Interfaces & Seams"): `routes` is a priority-ordered `{ route, versions? }[]`.
// The resolved version is the newest across the union of all routes' listings
// (numeric equality, e.g. runfile "10.0" == pip "10.0.0"), and when several routes
// ship the same resolved version, the first one in `routes` (priority) order wins.

describe('resolveAutoVersion with priority-ordered routes (Linux, 3 routes)', () => {
  it('AC-1: prefers runfile over pip when both ship the newest version under different version strings', () => {
    const routes = [
      { route: 'package-manager', versions: ['7.2.4'] },
      { route: 'runfile', versions: ['7.2.4', '10.0'] },
      { route: 'pip', versions: ['10.0.0'] },
    ];
    expect(resolveAutoVersion('latest', routes)).toEqual({ version: '10.0', route: 'runfile' });
  });

  it('AC-2: resolves to pip for a version neither package-manager nor runfile lists', () => {
    const routes = [
      { route: 'package-manager', versions: ['7.2.4'] },
      { route: 'runfile', versions: ['7.2.4', '9.5'] },
      { route: 'pip', versions: ['10.1.0'] },
    ];
    expect(resolveAutoVersion('latest', routes)).toEqual({ version: '10.1.0', route: 'pip' });
  });

  it('AC-3: prefers package-manager when all three routes ship the resolved version', () => {
    const routes = [
      { route: 'package-manager', versions: ['7.2.4'] },
      { route: 'runfile', versions: ['7.2.4'] },
      { route: 'pip', versions: ['7.2.4'] },
    ];
    expect(resolveAutoVersion('7.2', routes)).toEqual({
      version: '7.2.4',
      route: 'package-manager',
    });
  });
});

describe('resolveAutoVersion with priority-ordered routes (Windows, 2 routes)', () => {
  it('AC-4: prefers pip over the installer table when pip ships the newest version', () => {
    const routes = [
      { route: 'installer', versions: Object.keys(WINDOWS_HIP_SDK_INSTALLERS) },
      { route: 'pip', versions: ['10.0.0'] },
    ];
    expect(resolveAutoVersion('latest', routes)).toEqual({ version: '10.0.0', route: 'pip' });
  });

  it('AC-5: resolves a partial version from the installer table', () => {
    const routes = [
      { route: 'installer', versions: Object.keys(WINDOWS_HIP_SDK_INSTALLERS) },
      { route: 'pip', versions: ['10.0.0'] },
    ];
    expect(resolveAutoVersion('6.4', routes)).toEqual({ version: '6.4.2', route: 'installer' });
  });
});
