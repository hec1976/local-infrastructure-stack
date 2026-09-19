# Third-Party Notices

This repository contains or references third-party software. The following
list documents the directly vendored browser assets and the separately built
runtime component visible in this source tree.

| Component | Version / identification | License | Location |
| --- | --- | --- | --- |
| Bootstrap | 5.3.6 | MIT | `config-manager-standalone/public/assets/vendor/bootstrap/` |
| Bootstrap Icons | bundled CSS and embedded font | MIT | `config-manager-standalone/public/assets/vendor/bootstrap-icons/` |
| jQuery | 3.6.1 | MIT | `config-manager-standalone/public/assets/vendor/jquery/` |
| CodeMirror | upstream CodeMirror sources and modes | MIT | `config-manager-standalone/public/assets/vendor/ace-offline/` |

The files below are project-specific compatibility or styling layers and are
not unmodified upstream DataTables or Ace distributions:

- `config-manager-standalone/public/assets/vendor/datatables/`
- `config-manager-standalone/public/assets/vendor/ace-offline/ace-local-adapter.js`
- `config-manager-standalone/public/assets/vendor/inter/inter-local.css`

The Monit Prometheus exporter is built from the Go source stored under
`monit-exporter/`. Its prebuilt Linux/amd64 binary is included for offline
deployment. Rebuilds should use the module definition in `monit-exporter/go.mod`
and should update `SHA256SUMS`.

Copyright and license notices embedded in third-party files must be preserved.
Before public redistribution, the repository owner should verify this list
against the exact upstream files and versions used to create the release.
