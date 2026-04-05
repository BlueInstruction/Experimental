# Project Code Review Guidelines

## Review Focus
- Check ARM64EC compatibility and ABI correctness
- Validate memory management and descriptor handling
- Check Vulkan extension usage and driver compatibility
- Verify environment variable configurations

## Checks to Ignore
- Code style issues in auto-generated files
- Complexity warnings in build scripts

## Team Conventions
- Use Meson cross-files for all cross-compilation builds
- Document all VKD3D_CONFIG options used in patches
