import * as core from '@actions/core';
import * as exec from '@actions/exec';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as tc from '@actions/tool-cache';
import * as io from '@actions/io';
import { LinuxDistribution, isDebianBased, isFedoraBased } from './os_arch';
import { hasRootPrivileges } from './utils';
import { resolveRunfileUrl, findWindowsInstaller, notFoundError } from './rocm';
import {
  ROCM_GPG_KEY_URL,
  ROCM_APT_REPO_URL,
  ROCM_EL_REPO_URL,
  ROCM_META_PACKAGE,
  WINDOWS_HIP_SDK_INSTALLERS,
} from './const';

/**
 * Get sudo prefix for command execution
 * @returns 'sudo' if root privileges are not present, empty string otherwise
 */
function getSudoPrefix(): string {
  return hasRootPrivileges() ? '' : 'sudo';
}

/**
 * Get the runner's temp directory
 * @returns `RUNNER_TEMP` if set, otherwise the OS temp directory
 */
function getTempDir(): string {
  return process.env['RUNNER_TEMP'] || os.tmpdir();
}

/**
 * Write a file to a root-owned destination: directly if already root, otherwise via a
 * temp file installed with `sudo install` (setup-cuda's `getSudoPrefix` pattern)
 * @param content - File content to write
 * @param destination - Absolute destination path
 * @param sudoPrefix - 'sudo' or '' (from `getSudoPrefix`)
 */
async function writeRootFile(
  content: string,
  destination: string,
  sudoPrefix: string
): Promise<void> {
  if (!sudoPrefix) {
    fs.writeFileSync(destination, content);
    return;
  }
  const tempDir = getTempDir();
  const tempFile = path.join(tempDir, path.basename(destination));
  fs.writeFileSync(tempFile, content);
  await exec.exec(`sudo install -m 0644 ${tempFile} ${destination}`);
}

/**
 * Install the ROCm apt repository signing key, dearmored into /etc/apt/keyrings/rocm.gpg
 * @param sudoPrefix - 'sudo' or '' (from `getSudoPrefix`)
 */
async function installAptSigningKey(sudoPrefix: string): Promise<void> {
  const keyFile = await tc.downloadTool(ROCM_GPG_KEY_URL);
  const tempDir = getTempDir();
  const dearmoredKeyFile = path.join(tempDir, 'rocm.gpg');
  await exec.exec('gpg', ['--dearmor', '-o', dearmoredKeyFile, keyFile]);
  await exec.exec(
    `${sudoPrefix} install -D -m 0644 ${dearmoredKeyFile} /etc/apt/keyrings/rocm.gpg`.trim()
  );
  await io.rmRF(keyFile);
  await io.rmRF(dearmoredKeyFile);
}

/**
 * Register the ROCm apt repository and its companion (graphics/amdgpu) repository, pinned
 * above the distro's own packages
 * @param version - Resolved ROCm version
 * @param distro - Linux distribution information
 * @param companion - Companion (graphics/amdgpu) repo resolved by `resolveCompanionRepo`
 * @param sudoPrefix - 'sudo' or '' (from `getSudoPrefix`)
 */
async function registerAptRepositories(
  version: string,
  distro: LinuxDistribution,
  companion: { kind: 'graphics' | 'amdgpu'; url: string },
  sudoPrefix: string
): Promise<void> {
  const sourcesList =
    [
      `deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] ${ROCM_APT_REPO_URL(version)} ${distro.codename} main`,
      `deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] ${companion.url} ${distro.codename} main`,
    ].join('\n') + '\n';
  await writeRootFile(sourcesList, '/etc/apt/sources.list.d/rocm.list', sudoPrefix);

  const pinPreferences = 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n';
  await writeRootFile(pinPreferences, '/etc/apt/preferences.d/rocm-pin-600', sudoPrefix);
}

/**
 * Install ROCm on a Debian-based distribution via apt
 * @param version - Resolved ROCm version
 * @param distro - Linux distribution information
 * @param companion - Companion (graphics/amdgpu) repo resolved by `resolveCompanionRepo`
 */
async function installPackageManagerDebian(
  version: string,
  distro: LinuxDistribution,
  companion: { kind: 'graphics' | 'amdgpu'; url: string }
): Promise<void> {
  const sudoPrefix = getSudoPrefix();

  core.info('Installing ROCm apt signing key...');
  await installAptSigningKey(sudoPrefix);

  core.info(
    `Registering ROCm apt repository (${version}) and companion repo (${companion.kind})...`
  );
  await registerAptRepositories(version, distro, companion, sudoPrefix);

  const env = { ...process.env, DEBIAN_FRONTEND: 'noninteractive' };
  core.info('Running apt-get update...');
  await exec.exec(`${sudoPrefix} apt-get update`.trim(), undefined, { env });

  core.info(`Installing ${ROCM_META_PACKAGE}...`);
  await exec.exec(`${sudoPrefix} apt-get install -y ${ROCM_META_PACKAGE}`.trim(), undefined, {
    env,
  });
}

/**
 * Enable the RHEL-based repo required for `rocm-hip-sdk`'s dependencies: `powertools` on el8,
 * `crb` on el9/el10
 * @param major - RHEL major version (e.g. "9")
 * @param sudoPrefix - 'sudo' or '' (from `getSudoPrefix`)
 */
async function enableRhelCrbRepo(major: string, sudoPrefix: string): Promise<void> {
  const repoName = major === '8' ? 'powertools' : 'crb';
  await exec.exec(`${sudoPrefix} dnf config-manager --set-enabled ${repoName}`.trim());
}

/**
 * Build the /etc/yum.repos.d/rocm.repo content registering the ROCm repo and its companion
 * (graphics/amdgpu) repo
 * @param version - Resolved ROCm version
 * @param major - RHEL major version (e.g. "9")
 * @param companion - Companion (graphics/amdgpu) repo resolved by `resolveCompanionRepo`
 */
function buildRocmRepoFile(
  version: string,
  major: string,
  companion: { kind: 'graphics' | 'amdgpu'; url: string }
): string {
  return (
    [
      '[rocm]',
      `name=ROCm ${version} repository`,
      `baseurl=${ROCM_EL_REPO_URL(major, version)}`,
      'enabled=1',
      'priority=50',
      'gpgcheck=1',
      `gpgkey=${ROCM_GPG_KEY_URL}`,
      '',
      '[amdgraphics]',
      `name=AMD graphics ${version} repository`,
      `baseurl=${companion.url}`,
      'enabled=1',
      'priority=50',
      'gpgcheck=1',
      `gpgkey=${ROCM_GPG_KEY_URL}`,
    ].join('\n') + '\n'
  );
}

/**
 * Install ROCm on a RHEL-based (Fedora-based) distribution via dnf
 * @param version - Resolved ROCm version
 * @param distro - Linux distribution information
 * @param companion - Companion (graphics/amdgpu) repo resolved by `resolveCompanionRepo`
 */
async function installPackageManagerRhel(
  version: string,
  distro: LinuxDistribution,
  companion: { kind: 'graphics' | 'amdgpu'; url: string }
): Promise<void> {
  const sudoPrefix = getSudoPrefix();
  const major = distro.version.split('.')[0];

  core.info('Installing EPEL and dnf-plugins-core...');
  await exec.exec(`${sudoPrefix} dnf install -y epel-release dnf-plugins-core`.trim());

  core.info(`Enabling the ${major === '8' ? 'powertools' : 'crb'} repo...`);
  await enableRhelCrbRepo(major, sudoPrefix);

  core.info(
    `Registering ROCm dnf repository (${version}) and companion repo (${companion.kind})...`
  );
  await writeRootFile(
    buildRocmRepoFile(version, major, companion),
    '/etc/yum.repos.d/rocm.repo',
    sudoPrefix
  );

  core.info('Running dnf clean all...');
  await exec.exec(`${sudoPrefix} dnf clean all`.trim());

  core.info(`Installing ${ROCM_META_PACKAGE}...`);
  await exec.exec(`${sudoPrefix} dnf install -y ${ROCM_META_PACKAGE}`.trim());
}

/**
 * Verify that `hipcc` exists under /opt/rocm/bin, as installed by apt/dnf or the runfile installer
 * @returns The path to the ROCm installation ("/opt/rocm")
 */
function verifyLinuxRocmInstall(): string {
  const rocmPath = '/opt/rocm';
  const hipcc = path.join(rocmPath, 'bin', 'hipcc');
  if (!fs.existsSync(hipcc)) {
    throw new Error(`ROCm installation failed. hipcc not found: ${hipcc}`);
  }
  return rocmPath;
}

/**
 * Install ROCm via the distro's package manager (apt/dnf)
 * @param version - Resolved ROCm version (e.g. "7.2.4")
 * @param distro - Linux distribution information
 * @param companion - Companion (graphics/amdgpu) repo resolved by `resolveCompanionRepo`
 * @returns The path to the ROCm installation ("/opt/rocm")
 */
export async function installPackageManager(
  version: string,
  distro: LinuxDistribution,
  companion: { kind: 'graphics' | 'amdgpu'; url: string }
): Promise<string> {
  if (isDebianBased(distro)) {
    await installPackageManagerDebian(version, distro, companion);
  } else if (isFedoraBased(distro)) {
    await installPackageManagerRhel(version, distro, companion);
  } else {
    throw new Error(`Unsupported distribution for package-manager install: ${distro.id}`);
  }

  return verifyLinuxRocmInstall();
}

/**
 * Install ROCm via the runfile installer. Downloads the `.run` file to `RUNNER_TEMP`
 * and runs it there (its cwd, not the file's location, determines where it extracts and
 * cleans up its `rocm-installer/` working directory)
 * @param version - Resolved ROCm version (e.g. "10.0")
 * @param distro - Linux distribution information (used to resolve the `.run` URL)
 * @returns The path to the ROCm installation ("/opt/rocm")
 */
export async function installRunfile(version: string, distro: LinuxDistribution): Promise<string> {
  const url = await resolveRunfileUrl(version, distro);
  const tempDir = getTempDir();

  core.info(`Downloading ROCm runfile installer from ${url}...`);
  const installerPath = await tc.downloadTool(url, path.join(tempDir, path.basename(url)));

  // The new-generation (TheRock-based) runfile installer auto-detects the GPU when `gfx=`
  // is omitted and fails on GPU-less runners; `gfx=all` installs every architecture it
  // bundles instead. Its default component set (`core`) also lacks the HIP development
  // headers needed for cross-compilation; `compo=core-sdk` installs the complete SDK
  // instead. The old-generation installer doesn't accept either flag.
  const isNewGenInstaller = path.basename(url).startsWith('rocm-installer-');
  const installArgs = isNewGenInstaller
    ? 'rocm target=/ deps=install postrocm gfx=all compo=core-sdk'
    : 'rocm target=/ deps=install postrocm';
  if (isNewGenInstaller) {
    core.info(
      'New-generation runfile installer detected; passing gfx=all compo=core-sdk to skip GPU auto-detection and install the complete SDK.'
    );
  }

  const sudoPrefix = getSudoPrefix();
  core.info(`Installing ROCm ${version} via runfile installer...`);
  await exec.exec(`${sudoPrefix} bash ${installerPath} ${installArgs}`.trim(), undefined, {
    cwd: tempDir,
  });

  core.info('Cleaning up installer...');
  await io.rmRF(installerPath);

  return verifyLinuxRocmInstall();
}

/**
 * Install ROCm via the HIP SDK for Windows installer exe. The version-to-installer
 * table has no machine-readable index, so mapping errors surface here: the extracted directory
 * name is checked after install, not just the download
 * @param input - Raw `version` input
 * @returns The resolved version and the path to the ROCm installation
 */
export async function installWindows(
  input: string
): Promise<{ version: string; rocmPath: string }> {
  const resolved = findWindowsInstaller(input);
  if (!resolved) {
    throw notFoundError(input, [Object.keys(WINDOWS_HIP_SDK_INSTALLERS).join(', ')]);
  }
  const { version, url } = resolved;
  const tempDir = getTempDir();

  core.info(`Downloading ROCm HIP SDK installer for ${version} from ${url}...`);
  const installerPath = path.win32.normalize(
    await tc.downloadTool(url, path.win32.join(tempDir, `rocm-hip-sdk-${version}.exe`))
  );

  const logPath = path.win32.join(tempDir, 'rocm-install.log');
  core.info(`Installing ROCm ${version} via HIP SDK installer...`);
  try {
    await exec.exec(`"${installerPath}"`, ['-install', '-log', logPath]);
  } catch (error) {
    if (fs.existsSync(logPath)) {
      core.info(fs.readFileSync(logPath, 'utf-8').slice(-4000));
    }
    throw error;
  }

  const majorMinor = version.split('.').slice(0, 2).join('.');
  const rocmPath = path.win32.join('C:\\Program Files\\AMD\\ROCm', majorMinor);
  const hasHipcc = fs.existsSync(path.win32.join(rocmPath, 'bin', 'hipcc.bin.exe'));
  const hasClang = fs.existsSync(path.win32.join(rocmPath, 'bin', 'clang.exe'));
  if (!hasHipcc && !hasClang) {
    try {
      core.info(
        `Contents of C:\\Program Files\\AMD\\ROCm: ${fs.readdirSync('C:\\Program Files\\AMD\\ROCm').join(', ')}`
      );
    } catch {
      // ignore: directory may not exist
    }
    throw new Error(`ROCm installation failed. hipcc/clang not found under ${rocmPath}\\bin`);
  }

  core.info('Cleaning up installer...');
  await io.rmRF(installerPath);

  return { version, rocmPath };
}
