import { describe, it, expect } from 'vite-plus/test';
import { parseOsRelease } from '../src/os_arch';

// Real-world /etc/os-release content for the runner distros this action targets.
const UBUNTU_22_04 = `PRETTY_NAME="Ubuntu 22.04.3 LTS"
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION="22.04.3 LTS (Jammy Jellyfish)"
VERSION_CODENAME=jammy
ID=ubuntu
ID_LIKE=debian
HOME_URL="https://www.ubuntu.com/"
SUPPORT_URL="https://help.ubuntu.com/"
BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
UBUNTU_CODENAME=jammy
`;

const UBUNTU_24_04 = `PRETTY_NAME="Ubuntu 24.04.1 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04.1 LTS (Noble Numbat)"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian
HOME_URL="https://www.ubuntu.com/"
SUPPORT_URL="https://help.ubuntu.com/"
BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
UBUNTU_CODENAME=noble
`;

const ALMALINUX_9 = `NAME="AlmaLinux"
VERSION="9.4 (Seafoam Ocelot)"
ID="almalinux"
ID_LIKE="rhel centos fedora"
VERSION_ID="9.4"
PLATFORM_ID="platform:el9"
PRETTY_NAME="AlmaLinux 9.4 (Seafoam Ocelot)"
ANSI_COLOR="0;34"
LOGO="fedora-logo-icon"
CPE_NAME="cpe:/o:almalinux:almalinux:9::baseos"
HOME_URL="https://almalinux.org/"
DOCUMENTATION_URL="https://wiki.almalinux.org/"
BUG_REPORT_URL="https://bugs.almalinux.org/"
`;

describe('parseOsRelease', () => {
  it('parses Ubuntu 22.04 with codename jammy', () => {
    const result = parseOsRelease(UBUNTU_22_04);
    expect(result.id).toBe('ubuntu');
    expect(result.version).toBe('22.04');
    expect(result.codename).toBe('jammy');
  });

  it('parses Ubuntu 24.04 with codename noble', () => {
    const result = parseOsRelease(UBUNTU_24_04);
    expect(result.id).toBe('ubuntu');
    expect(result.version).toBe('24.04');
    expect(result.codename).toBe('noble');
  });

  it('parses AlmaLinux 9 with an empty codename', () => {
    const result = parseOsRelease(ALMALINUX_9);
    expect(result.id).toBe('almalinux');
    expect(result.version).toBe('9.4');
    expect(result.codename).toBe('');
  });
});
