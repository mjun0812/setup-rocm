import * as core from '@actions/core';
import { getOS, getArch, OS, getLinuxDistribution, getWindowsVersion } from './os_arch';
import { parseMethod } from './rocm';

async function run(): Promise<void> {
  try {
    // Get input version
    const inputVersion = core.getInput('version') || 'latest';
    core.info(`Input version: ${inputVersion}`);

    // Get input method
    const inputMethod = parseMethod(core.getInput('method'));
    core.info(`Input method: ${inputMethod}`);

    // Get OS and architecture
    const osType = getOS();
    const arch = getArch();
    core.info(`OS: ${osType}`);
    core.info(`Architecture: ${arch}`);

    // Get Linux distribution or Windows version
    if (osType === OS.LINUX) {
      const linuxDistribution = getLinuxDistribution();
      core.info(
        `Linux distribution: ${linuxDistribution.id} ${linuxDistribution.version} (${linuxDistribution.codename}) ${linuxDistribution.name} ${linuxDistribution.idLink}`
      );
    } else if (osType === OS.WINDOWS) {
      const windowsVersion = getWindowsVersion();
      core.info(
        `Windows version: ${windowsVersion.name} (${windowsVersion.release}, build ${windowsVersion.build})`
      );
    }
  } catch (error) {
    if (error instanceof Error) {
      core.setFailed(error.message);
    } else {
      core.setFailed('An unknown error occurred');
    }
  }
}

void run();
