import { describe, it, expect } from 'vite-plus/test';
import {
  parseMethod,
  findRocmVersion,
  notFoundError,
  selectFallbackAfterInstallFailure,
} from '../src/rocm';

describe('parseMethod', () => {
  it('rejects an invalid method value', () => {
    expect(() => parseMethod('foo')).toThrow(/foo/);
  });
});

// Modeled after a real repo.radeon.com/rocm/apt/ directory index: numeric
// version directories mixed with non-numeric entries (pre-release tags,
// package-with-suffix directories, and the `latest`/`debian` symlinks).
const ROCM_VERSIONS = [
  '1.9.3',
  '6.2.4',
  '7.0_alpha',
  '7.0_beta',
  '2.10.0-ipclang',
  '7.2.4',
  'latest',
  'debian',
];

describe('findRocmVersion', () => {
  it('resolves "latest" to the maximum numeric version', () => {
    expect(findRocmVersion('latest', ROCM_VERSIONS)).toBe('7.2.4');
  });

  it('resolves a major-only input to the latest matching version', () => {
    expect(findRocmVersion('7', ROCM_VERSIONS)).toBe('7.2.4');
  });

  it('resolves a major.minor input to the latest matching version', () => {
    expect(findRocmVersion('7.2', ROCM_VERSIONS)).toBe('7.2.4');
  });

  it('resolves a full major.minor.patch input via exact match', () => {
    expect(findRocmVersion('7.2.4', ROCM_VERSIONS)).toBe('7.2.4');
  });

  it('returns undefined for a version that does not exist', () => {
    expect(findRocmVersion('99.9', ROCM_VERSIONS)).toBeUndefined();
  });

  it('excludes non-numeric entries so they are never resolved as a match', () => {
    // Only '7.0_alpha' and '7.0_beta' look like 7.0.x candidates; both must
    // be excluded, leaving no 7.0.x version to resolve.
    expect(findRocmVersion('7.0', ROCM_VERSIONS)).toBeUndefined();
  });
});

describe('notFoundError', () => {
  it('includes the input version and the source URL in the message', () => {
    const error = notFoundError('99.9', ['https://repo.radeon.com/rocm/apt/']);
    expect(error).toBeInstanceOf(Error);
    expect(error.message).toContain('99.9');
    expect(error.message).toContain('https://repo.radeon.com/rocm/apt/');
  });

  it('includes every source URL when multiple are given', () => {
    const error = notFoundError('99.9', [
      'https://repo.radeon.com/rocm/apt/',
      'https://repo.radeon.com/rocm/installer/rocm-runfile-installer/',
    ]);
    expect(error.message).toContain('https://repo.radeon.com/rocm/apt/');
    expect(error.message).toContain(
      'https://repo.radeon.com/rocm/installer/rocm-runfile-installer/'
    );
  });
});

describe('selectFallbackAfterInstallFailure', () => {
  it('returns "runfile" when the resolved version exists in the runfile list', () => {
    expect(selectFallbackAfterInstallFailure('7.2.4', ['6.3.1', '7.2.4', '10.0.0'])).toBe(
      'runfile'
    );
  });

  it('returns undefined when the resolved version is absent from the runfile list', () => {
    expect(selectFallbackAfterInstallFailure('7.2.4', ['6.3.1', '10.0.0'])).toBeUndefined();
  });

  it('does not re-resolve: a prefix of a listed version is not treated as found', () => {
    // '7.2' is not itself a runfile entry, only '7.2.4' is; a prefix/re-resolution
    // match would incorrectly return 'runfile' here.
    expect(selectFallbackAfterInstallFailure('7.2', ['6.3.1', '7.2.4', '10.0.0'])).toBeUndefined();
  });
});
