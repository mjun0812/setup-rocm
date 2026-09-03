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
