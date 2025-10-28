# Changelog

All notable changes to the Brisk Kubernetes Provider will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-01-10

### Added
- Initial release of Kubernetes provider
- Dynamic pod creation on-demand
- Health management via Kubernetes probes
- Support for node selectors and tolerations
- Configurable resource requests and limits
- Automatic orphan pod cleanup via reconciliation
- Custom environment variable support
- Namespace isolation for projects
- Comprehensive test suite
- Full documentation with examples
- RBAC configuration templates
- Network policy examples

### Features
- ✅ Dynamic worker creation
- ✅ Auto-scaling support
- ✅ Health tracking (via Kubernetes)
- ✅ Resource management
- ✅ Node placement control
- ✅ Multi-namespace support
- ✅ Orphan cleanup

### Documentation
- README with installation and configuration guide
- RBAC setup examples
- Troubleshooting guide
- Architecture overview
- Advanced configuration examples

## [Unreleased]

### Planned
- Support for Kubernetes Jobs instead of bare Pods
- StatefulSet support for persistent workers
- Integration with Kubernetes Horizontal Pod Autoscaler
- Prometheus metrics export
- Support for pod priority classes
- Image pull secrets configuration
- Volume mount support for caching
- Init container support
- Sidecar container support
