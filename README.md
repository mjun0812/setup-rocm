# setup-rocm

[![GitHub release (latest by date)](https://img.shields.io/github/v/release/mjun0812/setup-rocm)](https://github.com/mjun0812/setup-rocm/releases)
[![GitHub](https://img.shields.io/github/license/mjun0812/setup-rocm)](https://github.com/mjun0812/setup-rocm)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Setup%20ROCm-blue.svg)](https://github.com/marketplace/actions/mjun0812-setup-rocm)  
[![github-sponsor](https://img.shields.io/badge/sponsor-30363D?style=for-the-badge&logo=GitHub-Sponsors&logoColor=#white)](https://github.com/sponsors/mjun0812)
[![buy-me-a-coffee](https://img.shields.io/badge/Buy_Me_A_Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/mjun0812)

Set up a specific version of AMD ROCm in GitHub Actions.

## Features

- 🚀 **Dynamic Version Selection**: Install any ROCm version without waiting for action updates
- 🎯 **Flexible Version Specification**: Support for `latest`, `Major`, `Major.Minor`, or `Major.Minor.Patch` formats
- ⚡️ **Automatic Installation Method Selection**: Intelligently chooses between the package-manager and runfile installers on Linux
- 💻 **Cross-Platform Support**: Works on both Linux (x86_64) and Windows (x86_64) runners
- 🥗 **Supports Both Debian-based and RHEL-based Distributions**: Works on Ubuntu and RHEL-based container/VM environments (AlmaLinux, etc.)
- 🛠️ **Environment Configuration**: Automatically sets up all necessary environment variables
- 🔧 **No GPU Required**: Installs the HIP build toolchain (hipcc, headers, libraries) for cross-compilation, without a ROCm-capable GPU or the amdgpu driver

## Tested Platforms

- **Linux**: ubuntu-22.04, ubuntu-24.04, container: almalinux:9, quay.io/pypa/manylinux_2_28_x86_64
- **Windows**: windows-2022, windows-2025

## Quick Start

```yaml
steps:
  - name: Setup ROCm
    uses: mjun0812/setup-rocm@v1
    with:
      version: '7.2'
```

## Usage Examples

### Install the latest ROCm version

```yaml
steps:
  - name: Setup latest ROCm
    uses: mjun0812/setup-rocm@v1
    with:
      version: 'latest'
```

### Install a specific major.minor version

The latest patch version will be automatically selected.

```yaml
steps:
  - name: Setup ROCm 7.2
    uses: mjun0812/setup-rocm@v1
    with:
      version: '7.2'
```

### Install a specific patch version

```yaml
steps:
  - name: Setup ROCm 7.2.4
    uses: mjun0812/setup-rocm@v1
    with:
      version: '7.2.4'
```

### Specify installation method

```yaml
steps:
  - name: Setup ROCm with the runfile installer
    uses: mjun0812/setup-rocm@v1
    with:
      version: '7.2'
      method: 'runfile' # or 'package-manager', 'auto'
```

### Install ROCm on a RHEL-based container

```yaml
TestContainer:
  runs-on: ubuntu-latest
  container:
    image: almalinux:9

  steps:
    - name: Install System Dependencies
      shell: bash
      run: |
        dnf install -y sudo

    - name: Setup ROCm
      uses: mjun0812/setup-rocm@v1
      with:
        version: '7.2'
```

### Windows

```yaml
steps:
  - name: Setup ROCm
    uses: mjun0812/setup-rocm@v1
    with:
      version: '6.4'
```

## Inputs

### `version`

**Description**: The version of AMD ROCm to install.

**Format**:

- `latest`: Install the latest available version
- `Major` (e.g., `7`): Install the latest minor version for the specified major version
- `Major.Minor` (e.g., `7.2`): Install the latest patch version for the specified major.minor version
- `Major.Minor.Patch` (e.g., `7.2.4`): Install the exact version specified

**Required**: No
**Default**: `latest`

### `method`

**Description**: The installation method to use on Linux. Ignored on Windows, where only the HIP SDK installer route exists; if set to anything other than `auto` there, an info log notes that it was ignored.

**Options**:

- `auto` (default): Tries `package-manager` first. If the requested version isn't available there, resolves it again against the `runfile` listing and falls back to `runfile`. If `package-manager` does find the version but the install itself fails, retries the same version via `runfile` without re-resolving it; if that version isn't available via `runfile` either, the original install error is raised
- `package-manager`: Installs ROCm from AMD's official apt (Debian-based) or dnf (RHEL-based) repository
- `runfile`: Downloads and runs AMD's official runfile installer

**Required**: No
**Default**: `auto`

## Outputs

### `version`

The full version string of AMD ROCm that was actually installed (e.g., `7.2.4`).

**Example**:

```yaml
- name: Setup ROCm
  id: rocm
  uses: mjun0812/setup-rocm@v1
  with:
    version: '7.2'

- name: Print installed version
  run: echo "Installed ROCm version ${{ steps.rocm.outputs.version }}"
```

### `rocm-path`

The absolute path to the AMD ROCm installation directory.

**Example**:

```yaml
- name: Setup ROCm
  id: rocm
  uses: mjun0812/setup-rocm@v1

- name: Use ROCm path
  run: echo "ROCm installed at ${{ steps.rocm.outputs.rocm-path }}"
```

## Environment Variables

This action automatically configures the following environment variables for subsequent steps:

### Common (Linux and Windows)

- `ROCM_PATH`: Path to the ROCm installation directory
- `ROCM_HOME`: Alias for `ROCM_PATH` (used by PyTorch's ROCm detection)
- `HIP_PATH`: Alias for `ROCM_PATH` (used by hipcc and CMake's HIP detection; required on Windows)
- `PATH`: Prepends `${ROCM_PATH}/bin` for access to ROCm binaries (hipcc, etc.)

### Linux-specific

- `LD_LIBRARY_PATH`: Prepends `${ROCM_PATH}/lib` for runtime library loading

## Supported Versions

### Linux

The list of available versions is fetched dynamically from AMD's official repository index at [repo.radeon.com](https://repo.radeon.com/) on every run; it is not hard-coded, so newly released versions are picked up automatically.

- **`package-manager`**: apt on Ubuntu 22.04 (jammy) / 24.04 (noble), and dnf on RHEL-based el8 / el9 / el10 (AlmaLinux, etc.). Installs the `rocm-hip-sdk` meta-package.
- **`runfile`**: Supports ROCm 6.3.1 and later. Installers for ROCm 7.12 and later (`rocm-installer-<version>-<n>.run`) automatically receive `gfx=all compo=core-sdk` so they skip GPU auto-detection (there is no GPU on the runner) and install the complete SDK, including headers.

There is no fixed lower version bound on Linux, but versions older than ROCm 6.x are not verified in CI.

### Windows

Windows uses AMD's HIP SDK installer, whose available versions are hard-coded in this action:

| ROCm version | Install directory               |
| ------------ | ------------------------------- |
| 5.5.1        | `C:\Program Files\AMD\ROCm\5.5` |
| 5.7.1        | `C:\Program Files\AMD\ROCm\5.7` |
| 6.1.2        | `C:\Program Files\AMD\ROCm\6.1` |
| 6.2.4        | `C:\Program Files\AMD\ROCm\6.2` |
| 6.4.2        | `C:\Program Files\AMD\ROCm\6.4` |
| 7.1.1        | `C:\Program Files\AMD\ROCm\7.1` |
| 7.2.0        | `C:\Program Files\AMD\ROCm\7.2` |

## Troubleshooting

### No space left on device

If you encounter an error like `No space left on device`, you can try to expand the disk space before running the action:

```yaml
- name: Expand disk space
  run: |
    df -h
    sudo rm -rf /usr/share/dotnet || true
    sudo rm -rf /usr/local/lib/android || true
    echo "-------"
    df -h
```

### Windows: HIP source fails to compile with MSVC 14.5x

HIP SDK 7.2's clang headers conflict with MSVC 14.5x's `cmath`. Pin an older MSVC toolset (14.44, bundled on both `windows-2022` and `windows-2025` images) with [ilammy/msvc-dev-cmd](https://github.com/ilammy/msvc-dev-cmd) before compiling:

```yaml
- name: Setup MSVC
  uses: ilammy/msvc-dev-cmd@v1
  with:
    arch: x64
    toolset: '14.44'
```

## Questions

### Why not just call apt/dnf or the installer directly from the workflow?

Existing ROCm wheel-build workflows (e.g. exllamav2, llama-cpp-python) call `apt-get`, `dnf`, or the HIP SDK installer exe directly, which means every workflow re-implements repository registration, distro/version branching, and environment variable setup, and pins a fixed ROCm version. This action installs ROCm from dynamically fetched version listings (so you can request `latest`, a major/minor version, or an exact patch version without waiting for an action update), picks the right route (`package-manager` or `runfile`) automatically, and configures `ROCM_PATH` / `ROCM_HOME` / `HIP_PATH` / `PATH` / `LD_LIBRARY_PATH` consistently across Linux and Windows.

### Does this support installing ROCm via pip wheels (`rocm[libraries,devel]`)?

Not currently. AMD's pip wheel distribution (`rocm[libraries,devel]`, `rocm_sdk_*`) is a future extension candidate, but v1 only supports the apt/dnf package-manager and runfile routes on Linux, and the HIP SDK installer on Windows.
