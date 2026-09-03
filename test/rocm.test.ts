import { describe, it, expect } from 'vite-plus/test';
import { parseMethod } from '../src/rocm';

describe('parseMethod', () => {
  it('rejects an invalid method value', () => {
    expect(() => parseMethod('foo')).toThrow(/foo/);
  });
});
