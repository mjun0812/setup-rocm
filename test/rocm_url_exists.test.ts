import { HttpClient, type HttpClientResponse } from '@actions/http-client';
import { afterEach, describe, expect, it, vi } from 'vite-plus/test';
import { urlExists } from '../src/rocm';

function fakeResponse(status: number, statusMessage = ''): HttpClientResponse {
  return {
    message: { statusCode: status, statusMessage },
    readBody: async () => '',
  } as unknown as HttpClientResponse;
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('urlExists', () => {
  it('returns true on HTTP 200', async () => {
    vi.spyOn(HttpClient.prototype, 'head').mockResolvedValue(fakeResponse(200));
    await expect(urlExists('https://repo.radeon.com/rocm/apt/7.2.4/dists/noble/')).resolves.toBe(
      true
    );
  });

  it('returns false on HTTP 404', async () => {
    vi.spyOn(HttpClient.prototype, 'head').mockResolvedValue(fakeResponse(404));
    await expect(urlExists('https://repo.radeon.com/rocm/apt/7.2.4/dists/noble/')).resolves.toBe(
      false
    );
  });

  it('throws on any other HTTP status instead of treating it as absent', async () => {
    vi.spyOn(HttpClient.prototype, 'head').mockResolvedValue(
      fakeResponse(503, 'Service Unavailable')
    );
    await expect(urlExists('https://repo.radeon.com/rocm/apt/7.2.4/dists/noble/')).rejects.toThrow(
      /503/
    );
  });

  it('throws on a network failure instead of treating it as absent', async () => {
    vi.spyOn(HttpClient.prototype, 'head').mockRejectedValue(new Error('connect ETIMEDOUT'));
    await expect(urlExists('https://repo.radeon.com/rocm/apt/7.2.4/dists/noble/')).rejects.toThrow(
      /ETIMEDOUT/
    );
  });
});
