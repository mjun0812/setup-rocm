import { HttpClient, type HttpClientResponse } from '@actions/http-client';
import { afterEach, describe, expect, it, vi } from 'vite-plus/test';
import { fetchElVersions } from '../src/rocm';

function fakeResponse(status: number, body = '', statusMessage = ''): HttpClientResponse {
  return {
    message: { statusCode: status, statusMessage },
    readBody: async () => body,
  } as unknown as HttpClientResponse;
}

const EL9_INDEX = `
<a href="../">../</a>
<a href="7.2.4/">7.2.4/</a>
<a href="7.1.1/">7.1.1/</a>
<a href="latest/">latest/</a>
`;

afterEach(() => {
  vi.restoreAllMocks();
});

describe('fetchElVersions', () => {
  it('lists the numeric versions of a published el<major> repository', async () => {
    vi.spyOn(HttpClient.prototype, 'get').mockResolvedValue(fakeResponse(200, EL9_INDEX));
    await expect(fetchElVersions('9')).resolves.toEqual(['7.1.1', '7.2.4']);
  });

  it('returns an empty listing when AMD publishes no repository for the major (HTTP 404)', async () => {
    vi.spyOn(HttpClient.prototype, 'get').mockResolvedValue(fakeResponse(404));
    await expect(fetchElVersions('2023')).resolves.toEqual([]);
  });

  it('throws on any other HTTP status instead of treating it as an empty listing', async () => {
    vi.spyOn(HttpClient.prototype, 'get').mockResolvedValue(
      fakeResponse(503, '', 'Service Unavailable')
    );
    await expect(fetchElVersions('9')).rejects.toThrow(/503/);
  });

  it('throws on a network failure instead of treating it as an empty listing', async () => {
    vi.spyOn(HttpClient.prototype, 'get').mockRejectedValue(new Error('connect ETIMEDOUT'));
    await expect(fetchElVersions('9')).rejects.toThrow(/ETIMEDOUT/);
  });
});
