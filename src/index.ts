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
  ROCM_APT_INDEX_URL,
  ROCM_EL_INDEX_URL,
  ROCM_RUNFILE_INDEX_URL,
} from './rocm';
import { installPackageManager, installRunfile, installWindows } from './install';
import { getErrorMessage } from './utils';

/**
 * Resolve the ROCm version and route (package-manager/runfile), then install ROCm on Linux.
 * @param inputVersion - Raw `version` input
 * @param method - Parsed `method` input
 * @param distro - Linux distribution information
 * @returns The resolved version and the path to the ROCm installation
 */
async function resolveAndInstallLinux(
  inputVersion: string,
  method: InstallMethod,
  distro: LinuxDistribution
): Promise<{ version: string; rocmPath: string }> {
  const debianBased = isDebianBased(distro);
  const major = distro.version.split('.')[0];
  const pmIndexUrl = debianBased ? ROCM_APT_INDEX_URL : ROCM_EL_INDEX_URL(major);

  let version: string | undefined;
  let route: 'package-manager' | 'runfile' | undefined;

  if (method === 'package-manager' || method === 'auto') {
    // Only fetch the package-manager version list for routes that can use it:
    // `method: runfile` resolves solely against the runfile list below.
    const pmVersions = debianBased
      ? await fetchAptVersions(distro.codename)
      : await fetchElVersions(major);
    version = findRocmVersion(inputVersion, pmVersions);
    if (version) {
      route = 'package-manager';
    } else if (method === 'package-manager') {
      throw notFoundError(inputVersion, [pmIndexUrl]);
    }
  }

  let runfileVersions: string[] | undefined;
  if (!route) {
    runfileVersions = await fetchRunfileVersions();
    version = findRocmVersion(inputVersion, runfileVersions);
    if (!version) {
      const sourceUrls =
        method === 'auto' ? [pmIndexUrl, ROCM_RUNFILE_INDEX_URL] : [ROCM_RUNFILE_INDEX_URL];
      throw notFoundError(inputVersion, sourceUrls);
    }
    route = 'runfile';
  }

  if (route === 'package-manager') {
    try {
      const companion = await resolveCompanionRepo(version!, distro);
      const rocmPath = await installPackageManager(version!, distro, companion);
      return { version: version!, rocmPath };
    } catch (installError) {
      runfileVersions = runfileVersions ?? (await fetchRunfileVersions());
      if (
        method === 'auto' &&
        selectFallbackAfterInstallFailure(version!, runfileVersions) === 'runfile'
      ) {
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
  return { version: version!, rocmPath };
}

/**
 * Export ROCm environment variables and add its bin directory to PATH
 * @param osType - Operating system type
 * @param rocmPath - Path to the ROCm installation
 */
function setEnvironmentVariables(osType: OS, rocmPath: string): void {
  core.exportVariable('ROCM_PATH', rocmPath);
  core.exportVariable('ROCM_HOME', rocmPath);
  core.exportVariable('HIP_PATH', rocmPath);
  core.addPath(path.join(rocmPath, 'bin'));
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
    } else {
      const windowsVersion = getWindowsVersion();
      core.info(
        `Windows version: ${windowsVersion.name} (${windowsVersion.release}, build ${windowsVersion.build})`
      );

      if (method !== 'auto') {
        core.info('The method input is ignored on Windows (HIP SDK installer only)');
      }

      const result = await installWindows(inputVersion);
      version = result.version;
      rocmPath = result.rocmPath;
    }

    // Set environment variables
    setEnvironmentVariables(osType, rocmPath);

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
