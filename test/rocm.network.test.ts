import { describe, it, expect } from 'vite-plus/test';
import { fetchAptVersions, fetchElVersions, fetchRunfileVersions } from '../src/rocm';

// These tests hit the real repo.radeon.com directory indexes, mirroring
// setup-cuda's test/cuda.test.ts approach of validating against the live
// source of truth instead of a fixture.

describe('fetchAptVersions (real network)', () => {
  it('includes a known published version for noble', async () => {
    const versions = await fetchAptVersions('noble');
    expect(versions).toContain('7.2.4');
  });
});

describe('fetchElVersions (real network)', () => {
  it('includes a known published version for el9', async () => {
    const versions = await fetchElVersions('9');
    expect(versions).toContain('7.2.4');
  });
});

describe('fetchRunfileVersions (real network)', () => {
  it('includes a known published version', async () => {
    const versions = await fetchRunfileVersions();
    expect(versions).toContain('7.2.4');
  });
});
