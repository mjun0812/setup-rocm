import * as core from '@actions/core';
import * as path from 'path';
import {
  getOS,
  getArch,
  OS,
  Arch,
  LinuxDistribution,
  getLinuxDistribution,
  getWindowsVersion,
  isDebianBased,
  isFedoraBased,
} from './os_arch';
import {
  parseMethod,
  InstallMethod,
  findRocmVersion,
  notFoundError,
  selectFallbackAfterInstallFailure,
  resolveCompanionRepo,
  fetchAptVersions,
  fetchElVersions,
  fetchRunfileVersions,
  fetchPipVersions,
  ROCM_APT_INDEX_URL,
  ROCM_EL_INDEX_URL,
  ROCM_RUNFILE_INDEX_URL,
  ROCM_PIP_CORE_INDEX_URL,
  resolveAutoVersion,
} from './rocm';
import type { InstallRoute } from './rocm';
import { WINDOWS_HIP_SDK_INSTALLERS } from './const';
import { installPackageManager, installRunfile, installWindows, installPip } from './install';
import { getErrorMessage } from './utils';

/**
 * Await a version listing, turning a fetch failure into a warning and `undefined`
 * @param listing - Pending version listing
 * @param indexUrl - Index the listing comes from (for the warning)
 * @returns The versions, or undefined when the index could not be fetched
 */
async function settleListing(
  listing: Promise<string[]>,
  indexUrl: string
): Promise<string[] | undefined> {
  try {
    return await listing;
  } catch (error) {
    core.warning(
      `Could not fetch the ROCm version listing from ${indexUrl}: ${getErrorMessage(error)}`
    );
    return undefined;
  }
}

/**
 * Resolve the ROCm version and route (package-manager/runfile/pip), then install ROCm on Linux.
 * @param inputVersion - Raw `version` input
 * @param method - Parsed `method` input
 * @param distro - Linux distribution information
 * @returns The resolved version, the path to the ROCm installation, (pip route only) its bin
 * directory, and whether the pip route was used
 */
async function resolveAndInstallLinux(
  inputVersion: string,
  method: InstallMethod,
  distro: LinuxDistribution
): Promise<{ version: string; rocmPath: string; binPath?: string; isPipRoute: boolean }> {
  const debianBased = isDebianBased(distro);
  const major = distro.version.split('.')[0];
  const pmIndexUrl = debianBased ? ROCM_APT_INDEX_URL : ROCM_EL_INDEX_URL(major);

  let version: string | undefined;
  let route: InstallRoute | undefined;
  let runfileVersions: string[] | undefined;

  const fetchPmVersions = () =>
    debianBased ? fetchAptVersions(distro.codename) : fetchElVersions(major);

  if (method === 'package-manager') {
    version = findRocmVersion(inputVersion, await fetchPmVersions());
    if (!version) {
      throw notFoundError(inputVersion, [pmIndexUrl]);
    }
    route = 'package-manager';
  } else if (method === 'runfile') {
    runfileVersions = await fetchRunfileVersions();
    version = findRocmVersion(inputVersion, runfileVersions);
    if (!version) {
      throw notFoundError(inputVersion, [ROCM_RUNFILE_INDEX_URL]);
    }
    route = 'runfile';
  } else if (method === 'pip') {
    version = findRocmVersion(inputVersion, await fetchPipVersions('linux_x86_64'));
    if (!version) {
      throw notFoundError(inputVersion, [ROCM_PIP_CORE_INDEX_URL]);
    }
    route = 'pip';
  } else {
    // auto: the newest match across all three routes wins, so `latest` is the newest ROCm
    // release even when only the runfile installer or the pip index ships it.
    // An index that cannot be fetched is reported and left out; resolveAutoVersion decides
    // whether the request can still be answered from the remaining listings.
    const [pmVersions, rfVersions, pipVersions] = await Promise.all([
      settleListing(fetchPmVersions(), pmIndexUrl),
      settleListing(fetchRunfileVersions(), ROCM_RUNFILE_INDEX_URL),
      settleListing(fetchPipVersions('linux_x86_64'), ROCM_PIP_CORE_INDEX_URL),
    ]);
    runfileVersions = rfVersions;
    const resolved = resolveAutoVersion(inputVersion, [
      { route: 'package-manager', versions: pmVersions },
      { route: 'runfile', versions: rfVersions },
      { route: 'pip', versions: pipVersions },
    ]);
    if (!resolved) {
      const sourceUrls = [
        ...(pmVersions ? [pmIndexUrl] : []),
        ...(rfVersions ? [ROCM_RUNFILE_INDEX_URL] : []),
        ...(pipVersions ? [ROCM_PIP_CORE_INDEX_URL] : []),
      ];
      throw notFoundError(inputVersion, sourceUrls);
    }
    ({ version, route } = resolved);
  }
  core.info(`Resolved ROCm ${version} via ${route}`);

  if (route === 'pip') {
    const { rocmPath, binPath } = await installPip(version!, OS.LINUX);
    return { version: version!, rocmPath, binPath, isPipRoute: true };
  }

  if (route === 'package-manager') {
    try {
      const companion = await resolveCompanionRepo(version!, distro);
      const rocmPath = await installPackageManager(version!, distro, companion);
      return { version: version!, rocmPath, isPipRoute: false };
    } catch (installError) {
      // Only `auto` may retry via the runfile, so only `auto` needs the runfile listing.
      // A listing that cannot be fetched must not hide the install error itself.
      if (method !== 'auto') {
        throw installError;
      }
      if (runfileVersions === undefined) {
        try {
          runfileVersions = await fetchRunfileVersions();
        } catch (listingError) {
          core.warning(
            `Could not fetch the ROCm runfile listing to retry ${version}: ${getErrorMessage(listingError)}`
          );
          throw installError;
        }
      }
      if (selectFallbackAfterInstallFailure(version!, runfileVersions) === 'runfile') {
        core.info(
          `package-manager install failed; retrying ${version} via runfile: ${getErrorMessage(installError)}`
        );
        route = 'runfile';
      } else {
        throw installError;
      }
    }
  }

  const rocmPath = await installRunfile(version!, distro);
  return { version: version!, rocmPath, isPipRoute: false };
}

/**
 * Resolve the ROCm version and route (installer/pip), then install ROCm on Windows.
 * `method: pip` is honored explicitly; `package-manager` and `runfile` are ignored (as
 * before Windows had a second route) and treated as `auto`.
 * @param inputVersion - Raw `version` input
 * @param method - Parsed `method` input
 * @returns The resolved version, the path to the ROCm installation, (pip route only) its bin
 * directory, and whether the pip route was used
 */
async function resolveAndInstallWindows(
  inputVersion: string,
  method: InstallMethod
): Promise<{ version: string; rocmPath: string; binPath?: string; isPipRoute: boolean }> {
  if (method === 'pip') {
    const version = findRocmVersion(inputVersion, await fetchPipVersions('win_amd64'));
    if (!version) {
      throw notFoundError(inputVersion, [ROCM_PIP_CORE_INDEX_URL]);
    }
    core.info(`Resolved ROCm ${version} via pip`);
    const { rocmPath, binPath } = await installPip(version, OS.WINDOWS);
    return { version, rocmPath, binPath, isPipRoute: true };
  }

  if (method !== 'auto') {
    core.info('The method input is ignored on Windows (installer and pip only)');
  }

  // auto: the newest match across the installer table and the pip index wins, so `latest`
  // is the newest ROCm release even when only pip ships it. The installer table is
  // built-in and never missing; only the pip listing can fail to fetch.
  const installerVersions = Object.keys(WINDOWS_HIP_SDK_INSTALLERS);
  const pipVersions = await settleListing(fetchPipVersions('win_amd64'), ROCM_PIP_CORE_INDEX_URL);
  const resolved = resolveAutoVersion(inputVersion, [
    { route: 'installer', versions: installerVersions },
    { route: 'pip', versions: pipVersions },
  ]);
  if (!resolved) {
    const sourceUrls = [
      installerVersions.join(', '),
      ...(pipVersions ? [ROCM_PIP_CORE_INDEX_URL] : []),
    ];
    throw notFoundError(inputVersion, sourceUrls);
  }
  const { version, route } = resolved;
  core.info(`Resolved ROCm ${version} via ${route}`);

  if (route === 'pip') {
    const { rocmPath, binPath } = await installPip(version, OS.WINDOWS);
    return { version, rocmPath, binPath, isPipRoute: true };
  }

  const result = await installWindows(version);
  return { version: result.version, rocmPath: result.rocmPath, isPipRoute: false };
}

/**
 * Build the ROCM_PATH/ROCM_HOME/HIP_PATH environment variables for the resolved installation,
 * plus (pip route only) HIP_DEVICE_LIB_PATH.
 *
 * clang's RocmInstallationDetector only looks for the device bitcode under
 * `<ROCM_PATH>/amdgcn/bitcode`, but the pip route's TheRock tree keeps it under
 * `lib/llvm/amdgcn/bitcode` instead, so hipcc needs HIP_DEVICE_LIB_PATH pointed at it directly
 * (the same workaround TheRock's own build scripts use).
 * @param rocmPath - Path to the ROCm installation
 * @param isPipRoute - Whether ROCm was installed via the pip route
 * @returns Environment variable name/value pairs to export
 */
function buildRocmEnvironmentVariables(
  rocmPath: string,
  isPipRoute: boolean
): { name: string; value: string }[] {
  const vars = [
    { name: 'ROCM_PATH', value: rocmPath },
    { name: 'ROCM_HOME', value: rocmPath },
    { name: 'HIP_PATH', value: rocmPath },
  ];
  if (isPipRoute) {
    vars.push({
      name: 'HIP_DEVICE_LIB_PATH',
      value: path.join(rocmPath, 'lib', 'llvm', 'amdgcn', 'bitcode'),
    });
  }
  return vars;
}

/**
 * Export ROCm environment variables and add its bin directory to PATH
 * @param osType - Operating system type
 * @param rocmPath - Path to the ROCm installation
 * @param binPath - Bin directory to add to PATH (pip route only; defaults to `<rocmPath>/bin`)
 * @param isPipRoute - Whether ROCm was installed via the pip route
 */
function setEnvironmentVariables(
  osType: OS,
  rocmPath: string,
  binPath: string | undefined,
  isPipRoute: boolean
): void {
  for (const { name, value } of buildRocmEnvironmentVariables(rocmPath, isPipRoute)) {
    core.exportVariable(name, value);
  }
  core.addPath(binPath ?? path.join(rocmPath, 'bin'));
  if (osType === OS.LINUX) {
    // Never leave an empty element (trailing ':'): the dynamic linker would
    // search the current working directory for it.
    const rocmLib = path.join(rocmPath, 'lib');
    const existing = process.env.LD_LIBRARY_PATH;
    core.exportVariable('LD_LIBRARY_PATH', existing ? `${rocmLib}:${existing}` : rocmLib);
  }
}

async function run(): Promise<void> {
  try {
    // Get input version
    const inputVersion = core.getInput('version') || 'latest';
    core.info(`Input version: ${inputVersion}`);

    // Get input method
    const method = parseMethod(core.getInput('method'));
    core.info(`Input method: ${method}`);

    // Get OS and architecture
    const osType = getOS();
    const arch = getArch();
    core.info(`OS: ${osType}`);
    core.info(`Architecture: ${arch}`);

    if (arch !== Arch.X86_64) {
      throw new Error(`ROCm is not supported on ${osType} with ${arch} architecture`);
    }

    let version: string;
    let rocmPath: string;
    let binPath: string | undefined;
    let isPipRoute: boolean;

    if (osType === OS.LINUX) {
      const distro = getLinuxDistribution();
      core.info(
        `Linux distribution: ${distro.id} ${distro.version} (${distro.codename}) ${distro.name} ${distro.idLink}`
      );

      if (!isDebianBased(distro) && !isFedoraBased(distro)) {
        throw new Error(`Unsupported Linux distribution: ${distro.id}`);
      }

      const result = await resolveAndInstallLinux(inputVersion, method, distro);
      version = result.version;
      rocmPath = result.rocmPath;
      binPath = result.binPath;
      isPipRoute = result.isPipRoute;
    } else {
      const windowsVersion = getWindowsVersion();
      core.info(
        `Windows version: ${windowsVersion.name} (${windowsVersion.release}, build ${windowsVersion.build})`
      );

      const result = await resolveAndInstallWindows(inputVersion, method);
      version = result.version;
      rocmPath = result.rocmPath;
      binPath = result.binPath;
      isPipRoute = result.isPipRoute;
    }

    // Set environment variables
    setEnvironmentVariables(osType, rocmPath, binPath, isPipRoute);

    // Set outputs
    core.setOutput('version', version);
    core.setOutput('rocm-path', rocmPath);
    core.info('ROCm installation completed successfully');
  } catch (error) {
    if (error instanceof Error) {
      core.setFailed(error.message);
    } else {
      core.setFailed('An unknown error occurred');
    }
  }
}

void run();
