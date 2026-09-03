import { HttpClient } from '@actions/http-client';
import { sortVersions } from './utils';

/**
 * Supported ROCm installation methods
 */
export type InstallMethod = 'package-manager' | 'runfile' | 'auto';

/**
 * Parse and validate the `method` input
 * @param input - Raw `method` input value
 * @returns The validated install method
 */
export function parseMethod(input: string): InstallMethod {
  if (input === '') {
    return 'auto';
  }
  if (input === 'package-manager' || input === 'runfile' || input === 'auto') {
    return input;
  }
  throw new Error(`Invalid method: ${input}. Valid methods are: package-manager, runfile, auto`);
}

/**
 * Base URL for the AMD ROCm apt repository directory index
 */
export const ROCM_APT_INDEX_URL = 'https://repo.radeon.com/rocm/apt/';

/**
 * Base URL for the AMD ROCm el<major> (RHEL-based) repository directory index
 * @param major - RHEL major version (e.g., "9")
 * @returns The el<major> repository directory index URL
 */
export function ROCM_EL_INDEX_URL(major: string): string {
  return `https://repo.radeon.com/rocm/el${major}/`;
}

/**
 * Base URL for the AMD ROCm runfile installer directory index
 */
export const ROCM_RUNFILE_INDEX_URL =
  'https://repo.radeon.com/rocm/installer/rocm-runfile-installer/';

/**
 * Pattern matching a purely numeric ROCm version directory name (e.g., "7.2.4")
 */
const NUMERIC_VERSION_PATTERN = /^\d+\.\d+(\.\d+)?$/;

/**
 * Parse an Apache-style directory listing HTML page into its directory entry names
 * @param html - The directory index HTML
 * @returns Directory entry names (trailing `/` removed), for links that point to a subdirectory
 */
export function parseDirectoryIndex(html: string): string[] {
  const linkPattern = /<a\s+href=['"]([^'"]+)['"]/gi;
  const entries = new Set<string>();

  let match;
  while ((match = linkPattern.exec(html)) !== null) {
    const href = match[1];
    if (href === '../' || !href.endsWith('/')) {
      continue;
    }
    entries.add(href.slice(0, -1));
  }

  return [...entries];
}

/**
 * Filter directory entries down to purely numeric ROCm versions, sorted ascending
 * @param entries - Directory entry names
 * @returns Numeric version strings, sorted ascending
 */
function filterNumericVersions(entries: string[]): string[] {
  return sortVersions(entries.filter((entry) => NUMERIC_VERSION_PATTERN.test(entry)));
}

/**
 * Check whether a URL exists (returns HTTP 200)
 * @param url - The URL to check
 * @returns Promise that resolves to true if the URL responds with HTTP 200
 */
export async function urlExists(url: string): Promise<boolean> {
  const client = new HttpClient('setup-rocm');
  try {
    const response = await client.head(url);
    return response.message.statusCode === 200;
  } catch {
    return false;
  }
}

/**
 * Fetch available ROCm versions from the apt repository that are published for the given codename
 * @param codename - Debian-based distribution codename (e.g., "noble")
 * @returns Promise that resolves to numeric version strings available for the codename, sorted ascending
 */
export async function fetchAptVersions(codename: string): Promise<string[]> {
  const client = new HttpClient('setup-rocm');
  const response = await client.get(ROCM_APT_INDEX_URL);
  if (response.message.statusCode !== 200) {
    throw new Error(
      `Failed to fetch ROCm apt index from ${ROCM_APT_INDEX_URL}: ${response.message.statusCode} ${response.message.statusMessage}`
    );
  }
  const html = await response.readBody();
  const versions = filterNumericVersions(parseDirectoryIndex(html));

  const exists = await Promise.all(
    versions.map((version) => urlExists(`${ROCM_APT_INDEX_URL}${version}/dists/${codename}/`))
  );
  return versions.filter((_version, index) => exists[index]);
}

/**
 * Fetch available ROCm versions from the el<major> (RHEL-based) repository
 * @param major - RHEL major version (e.g., "9")
 * @returns Promise that resolves to numeric version strings, sorted ascending
 */
export async function fetchElVersions(major: string): Promise<string[]> {
  const url = ROCM_EL_INDEX_URL(major);
  const client = new HttpClient('setup-rocm');
  const response = await client.get(url);
  if (response.message.statusCode !== 200) {
    throw new Error(
      `Failed to fetch ROCm el${major} index from ${url}: ${response.message.statusCode} ${response.message.statusMessage}`
    );
  }
  const html = await response.readBody();
  return filterNumericVersions(parseDirectoryIndex(html));
}

/**
 * Fetch available ROCm versions from the runfile installer directory index
 * @returns Promise that resolves to numeric version strings, sorted ascending
 */
export async function fetchRunfileVersions(): Promise<string[]> {
  const client = new HttpClient('setup-rocm');
  const response = await client.get(ROCM_RUNFILE_INDEX_URL);
  if (response.message.statusCode !== 200) {
    throw new Error(
      `Failed to fetch ROCm runfile index from ${ROCM_RUNFILE_INDEX_URL}: ${response.message.statusCode} ${response.message.statusMessage}`
    );
  }
  const html = await response.readBody();
  const entries = parseDirectoryIndex(html)
    .filter((entry) => entry.startsWith('rocm-rel-'))
    .map((entry) => entry.slice('rocm-rel-'.length));
  return filterNumericVersions(entries);
}

/**
 * Find a matching ROCm version from an available versions list
 * Non-numeric entries (e.g., "7.0_alpha", "latest") are excluded before matching
 * @param input - Version string to match (e.g., "latest", "7", "7.2", "7.2.4")
 * @param versions - Available version strings (may include non-numeric entries)
 * @returns The matched version string, or undefined if not found
 *
 * @example
 * findRocmVersion('latest', versions) // Returns the latest available version
 * findRocmVersion('7', versions) // Returns the latest 7.x version
 * findRocmVersion('7.2', versions) // Returns the latest 7.2.x version
 * findRocmVersion('7.2.4', versions) // Returns '7.2.4' if available
 */
export function findRocmVersion(input: string, versions: string[]): string | undefined {
  const available = filterNumericVersions(versions);

  // Case 1: "latest" returns the newest version
  if (input === 'latest') {
    return available[available.length - 1];
  }

  // Case 2: Exact match
  if (available.includes(input)) {
    return input;
  }

  // Case 3: Prefix match (e.g., "7" matches "7.x", "7.2" matches "7.2.x")
  const prefix = `${input}.`;
  const matching = available.filter((version) => version.startsWith(prefix));
  if (matching.length > 0) {
    return matching[matching.length - 1];
  }

  // Case 4: No match found
  return undefined;
}

/**
 * Build the error raised when a ROCm `version` input cannot be resolved
 * @param input - The unresolved `version` input value
 * @param sourceUrls - The version list URLs that were checked
 * @returns An Error describing the unresolved input and where it was checked
 */
export function notFoundError(input: string, sourceUrls: string[]): Error {
  return new Error(`ROCm version (${input}) is not found. Checked: ${sourceUrls.join(', ')}`);
}

/**
 * Decide the fallback route after a `package-manager` install failure under `method: auto`
 * The already-resolved version is not re-resolved; only an exact match in the runfile list counts
 * @param version - The already-resolved ROCm version
 * @param runfileVersions - Available runfile versions
 * @returns 'runfile' if the same version is available via runfile, otherwise undefined
 */
export function selectFallbackAfterInstallFailure(
  version: string,
  runfileVersions: string[]
): 'runfile' | undefined {
  return runfileVersions.includes(version) ? 'runfile' : undefined;
}
