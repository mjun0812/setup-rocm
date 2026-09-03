import { HttpClient } from '@actions/http-client';
import { sortVersions } from './utils';
import { isDebianBased, LinuxDistribution } from './os_arch';
import { WINDOWS_HIP_SDK_INSTALLERS } from './const';

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
 * Parse an Apache-style directory listing HTML page into its raw link hrefs
 * @param html - The directory index HTML
 * @returns Link href values (directories and files alike), excluding the parent-directory link ("../")
 */
export function parseIndexLinks(html: string): string[] {
  const linkPattern = /<a\s+href=['"]([^'"]+)['"]/gi;
  const entries: string[] = [];

  let match;
  while ((match = linkPattern.exec(html)) !== null) {
    const href = match[1];
    if (href === '../') {
      continue;
    }
    entries.push(href);
  }

  return entries;
}

/**
 * Parse an Apache-style directory listing HTML page into its directory entry names
 * @param html - The directory index HTML
 * @returns Directory entry names (trailing `/` removed), for links that point to a subdirectory
 */
export function parseDirectoryIndex(html: string): string[] {
  const entries = new Set<string>();
  for (const href of parseIndexLinks(html)) {
    if (href.endsWith('/')) {
      entries.add(href.slice(0, -1));
    }
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

/**
 * Fetch a directory index and pick out the `.run` file entry, if any
 * @param client - HttpClient used to fetch the index
 * @param url - Directory index URL
 * @returns The `.run` filename found at this index, or undefined if the index does not
 * exist (non-200) or contains no `.run` file
 */
async function findRunfileInIndex(client: HttpClient, url: string): Promise<string | undefined> {
  const response = await client.get(url);
  if (response.message.statusCode !== 200) {
    return undefined;
  }
  const html = await response.readBody();
  return parseIndexLinks(html).find((entry) => !entry.endsWith('/') && entry.endsWith('.run'));
}

/**
 * Resolve the `.run` installer URL for a ROCm version from the runfile installer directory index
 * The `.run` file is either directly under the release directory (e.g. 7.14.1), or under a
 * distro-specific subdirectory (`ubuntu/<VERSION_ID>/` or `el<major>/`, e.g. 7.2.4)
 * @param version - Resolved ROCm version (e.g. "7.2.4")
 * @param distro - Linux distribution information used to pick the distro-specific subdirectory
 * @returns Promise that resolves to the `.run` installer URL
 */
export async function resolveRunfileUrl(
  version: string,
  distro: LinuxDistribution
): Promise<string> {
  const client = new HttpClient('setup-rocm');
  const releaseUrl = `${ROCM_RUNFILE_INDEX_URL}rocm-rel-${version}/`;

  const runFile = await findRunfileInIndex(client, releaseUrl);
  if (runFile) {
    return `${releaseUrl}${runFile}`;
  }

  const subdir = isDebianBased(distro)
    ? `ubuntu/${distro.version}/`
    : `el${distro.version.split('.')[0]}/`;
  const subdirUrl = `${releaseUrl}${subdir}`;
  const subdirRunFile = await findRunfileInIndex(client, subdirUrl);
  if (subdirRunFile) {
    return `${subdirUrl}${subdirRunFile}`;
  }

  throw new Error(
    `ROCm runfile installer for version ${version} was not found. Checked: ${releaseUrl}, ${subdirUrl}`
  );
}

/**
 * Select the RHEL companion repo `<osver>` directory from an index of available osvers
 * Prefers an exact match on `VERSION_ID`; otherwise falls back to the largest osver within
 * the same major version (e.g. VERSION_ID "9.5" falls back among "9", "9.4", "9.7", ...)
 * @param osvers - Available osver directory names
 * @param versionId - Distro `VERSION_ID` (e.g. "9.6")
 * @returns The selected osver, or undefined if none match
 */
function selectRhelOsver(osvers: string[], versionId: string): string | undefined {
  if (osvers.includes(versionId)) {
    return versionId;
  }
  const major = versionId.split('.')[0];
  const sameMajor = osvers.filter((osver) => osver === major || osver.startsWith(`${major}.`));
  if (sameMajor.length === 0) {
    return undefined;
  }
  return sortVersions(sameMajor)[sameMajor.length - 1];
}

/**
 * Resolve the graphics/amdgpu companion repo for the Debian-based package-manager route
 * Selects the graphics repo (7.0+) if it exists, otherwise falls back to the amdgpu repo
 * @param version - Resolved ROCm version
 * @returns Promise that resolves to the companion repo kind and URL (no trailing slash)
 */
async function resolveDebianCompanionRepo(
  version: string
): Promise<{ kind: 'graphics' | 'amdgpu'; url: string }> {
  for (const kind of ['graphics', 'amdgpu'] as const) {
    const indexUrl = `https://repo.radeon.com/${kind}/${version}/ubuntu/`;
    if (await urlExists(indexUrl)) {
      return { kind, url: indexUrl.slice(0, -1) };
    }
  }
  throw new Error(
    `ROCm companion repo (graphics/amdgpu) for version ${version} was not found. Checked: ` +
      `https://repo.radeon.com/graphics/${version}/ubuntu/, https://repo.radeon.com/amdgpu/${version}/ubuntu/`
  );
}

/**
 * Resolve the graphics/amdgpu companion repo for the RHEL-based package-manager route
 * Selects the graphics repo (7.0+) if it exists, otherwise falls back to the amdgpu repo,
 * then picks the `<osver>` directory matching the distro's `VERSION_ID` (see `selectRhelOsver`)
 * @param version - Resolved ROCm version
 * @param distro - Linux distribution information (`VERSION_ID` drives the osver selection)
 * @returns Promise that resolves to the companion repo kind and URL (trailing slash)
 */
async function resolveRhelCompanionRepo(
  version: string,
  distro: LinuxDistribution
): Promise<{ kind: 'graphics' | 'amdgpu'; url: string }> {
  const client = new HttpClient('setup-rocm');

  for (const kind of ['graphics', 'amdgpu'] as const) {
    const indexUrl = `https://repo.radeon.com/${kind}/${version}/rhel/`;
    const response = await client.get(indexUrl);
    if (response.message.statusCode !== 200) {
      continue;
    }
    const html = await response.readBody();
    const osver = selectRhelOsver(parseDirectoryIndex(html), distro.version);
    if (!osver) {
      throw new Error(
        `ROCm ${kind} repo has no osver matching RHEL VERSION_ID ${distro.version} at ${indexUrl}`
      );
    }
    return { kind, url: `https://repo.radeon.com/${kind}/${version}/rhel/${osver}/main/x86_64/` };
  }

  throw new Error(
    `ROCm companion repo (graphics/amdgpu) for version ${version} was not found. Checked: ` +
      `https://repo.radeon.com/graphics/${version}/rhel/, https://repo.radeon.com/amdgpu/${version}/rhel/`
  );
}

/**
 * Resolve the graphics/amdgpu companion repo required by the `rocm-hip-sdk` package-manager
 * install (D-009). Debian-based distros check for repo existence directly; RHEL-based distros
 * additionally resolve the `<osver>` subdirectory matching `VERSION_ID`
 * @param version - Resolved ROCm version
 * @param distro - Linux distribution information
 * @returns Promise that resolves to the companion repo kind and URL
 */
export async function resolveCompanionRepo(
  version: string,
  distro: LinuxDistribution
): Promise<{ kind: 'graphics' | 'amdgpu'; url: string }> {
  if (isDebianBased(distro)) {
    return resolveDebianCompanionRepo(version);
  }
  return resolveRhelCompanionRepo(version, distro);
}

/**
 * Resolve the HIP SDK for Windows installer for a `version` input from the hard-coded
 * version-to-installer table (D-011)
 * @param input - Version string to match (e.g., "latest", "6.4", "7.2.0")
 * @returns The matched version and installer URL, or undefined if not found
 */
export function findWindowsInstaller(input: string): { version: string; url: string } | undefined {
  const version = findRocmVersion(input, Object.keys(WINDOWS_HIP_SDK_INSTALLERS));
  if (!version) {
    return undefined;
  }
  return { version, url: WINDOWS_HIP_SDK_INSTALLERS[version] };
}
