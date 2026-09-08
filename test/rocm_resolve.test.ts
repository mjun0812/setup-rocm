import { describe, it, expect } from 'vite-plus/test';
import { findRocmVersion } from '../src/rocm';

// D-020: a partial input (Major / Major.Minor) resolves to the latest matching version
// even when the input string is itself a listed entry, because runfile/apt listings mix
// a bare release (e.g. "7.14" = 7.14.0) with its later patches (e.g. "7.14.1").
const VERSIONS = ['7.14', '7.14.1', '10.0'];

describe('findRocmVersion (D-020: partial input vs. a same-named listed entry)', () => {
  it('resolves "7.14" to the latest 7.14.x entry, not the listed "7.14" itself', () => {
    expect(findRocmVersion('7.14', VERSIONS)).toBe('7.14.1');
  });

  it('resolves "7.14.1" (3 elements) via exact match', () => {
    expect(findRocmVersion('7.14.1', VERSIONS)).toBe('7.14.1');
  });

  it('resolves "7" to the latest 7.x entry', () => {
    expect(findRocmVersion('7', VERSIONS)).toBe('7.14.1');
  });

  it('resolves "10.0" to the listed "10.0" itself when no later patch exists', () => {
    expect(findRocmVersion('10.0', VERSIONS)).toBe('10.0');
  });
});
