import { describe, it, expect } from 'vite-plus/test';
import { parseMethod, parsePipIndex } from '../src/rocm';

describe('parseMethod with pip', () => {
  it('accepts pip as a valid method', () => {
    expect(parseMethod('pip')).toBe('pip');
  });

  it('still rejects an invalid method value', () => {
    expect(() => parseMethod('foo')).toThrow(/foo/);
  });
});

// Modeled after the PEP 503 simple index shape at
// https://stable.repo.amd.com/rocm/whl-next/rocm-sdk-core/: anchors named after
// the wheel filename, with a "#sha256=..." fragment attached to the href. The
// versions here are invented (not real ROCm releases) so the test exercises the
// parsing/filtering rule itself rather than a fixed spec example.
function pipIndex(entries: string[]): string {
  return entries.map((entry) => `<a href="${entry}#sha256=abc123">${entry}</a>`).join('\n');
}

const INDEX = pipIndex([
  'rocm_sdk_core-11.3.1-py3-none-linux_x86_64.whl',
  'rocm_sdk_core-12.0.0-py3-none-linux_x86_64.whl',
  'rocm_sdk_core-12.0.0-py3-none-win_amd64.whl',
  'rocm_sdk_core-13.0.0-py3-none-win_amd64.whl',
  'rocm_sdk_core-12.1.0rc1-py3-none-linux_x86_64.whl', // pre-release, not Major.Minor.Patch
  'rocm_sdk_core-9.0-py3-none-linux_x86_64.whl', // Major.Minor only, not Major.Minor.Patch
]);

describe('parsePipIndex', () => {
  it('lists only the versions with a matching wheel for linux_x86_64', () => {
    expect(parsePipIndex(INDEX, 'linux_x86_64').sort()).toEqual(['11.3.1', '12.0.0']);
  });

  it('lists only the versions with a matching wheel for win_amd64', () => {
    expect(parsePipIndex(INDEX, 'win_amd64').sort()).toEqual(['12.0.0', '13.0.0']);
  });
});
