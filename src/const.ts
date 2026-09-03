// WINDOWS_HIP_SDK_INSTALLERS: Maps a ROCm version to its HIP SDK for Windows installer URL.
// AMD does not publish a machine-readable version index for the Windows installer (D-011),
// so this table is hard-coded, the same way setup-cuda hard-codes CUDA_LINKS for versions
// without a dynamic listing.
export const WINDOWS_HIP_SDK_INSTALLERS: Record<string, string> = {
  '5.5.1':
    'https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-23.Q3-Win10-Win11-For-HIP.exe',
  '5.7.1':
    'https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-23.Q4-Win10-Win11-For-HIP.exe',
  '6.1.2':
    'https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-24.Q3-Win10-Win11-For-HIP.exe',
  '6.2.4':
    'https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-24.Q4-Win10-Win11-For-HIP.exe',
  '6.4.2':
    'https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-25.Q3-Win10-Win11-For-HIP.exe',
  '7.1.1':
    'https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-26.Q1-Win11-For-HIP.exe',
  '7.2.0':
    'https://download.amd.com/developer/eula/rocm-hub/AMD-Software-PRO-Edition-26.Q3-Win11-For-HIP.exe',
};

/**
 * The rocm-hip-sdk meta-package installed via apt/dnf (D-003)
 */
export const ROCM_META_PACKAGE = 'rocm-hip-sdk';

/**
 * URL of the ROCm apt repository's GPG signing key (D-012)
 */
export const ROCM_GPG_KEY_URL = 'https://repo.radeon.com/rocm/rocm.gpg.key';

/**
 * Debian-based ROCm apt repository URL for a given version, used in the sources.list entry (D-012)
 * @param version - Resolved ROCm version (e.g. "7.2.4")
 * @returns The ROCm apt repository URL (no trailing slash)
 */
export function ROCM_APT_REPO_URL(version: string): string {
  return `https://repo.radeon.com/rocm/apt/${version}`;
}
