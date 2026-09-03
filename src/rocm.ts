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
