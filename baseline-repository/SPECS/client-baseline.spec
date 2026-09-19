Name:           client-baseline
Version:        1.2.8
Release:        1%{?dist}
Summary:        Package baseline for managed Linux clients
License:        Proprietary
BuildRequires:  systemd-rpm-macros
BuildArch:      noarch
Provides:       teko-client-baseline = %{version}-%{release}
Obsoletes:      teko-client-baseline < 1.2.8
Requires:       monit
Requires:       alloy
Requires:       monit-prometheus-exporter >= 1.1.0
Requires:       python3

%description
Meta package for the generic managed-client software baseline. The package owns the generic observability configuration for Alloy and the
Monit exporter. Config Manager Client Baseline owns only the Monit access
credential and host identity.

%prep
%build
%install
mkdir -p %{buildroot}%{_datadir}/client-baseline
printf '%s\n' 'managed-client-baseline=1' > %{buildroot}%{_datadir}/client-baseline/installed
install -D -m 0644 %{_sourcedir}/alloy-baseline.conf %{buildroot}%{_unitdir}/alloy.service.d/10-infrastructure-baseline.conf
install -D -m 0755 %{_sourcedir}/configure-observability-client.sh %{buildroot}%{_libexecdir}/client-baseline/configure-observability-client

%post
# Runtime-Aktivierung gehoert bewusst in observability-client/install.sh.
# Das RPM darf bei Upgrade keinen bereits fehlerhaften Alloy-Dienst automatisch
# neu starten und dadurch die eigentliche Installationsdiagnose verdecken.
systemctl daemon-reload >/dev/null 2>&1 || :

%postun
systemctl daemon-reload >/dev/null 2>&1 || :

%files
%{_datadir}/client-baseline/installed
%{_unitdir}/alloy.service.d/10-infrastructure-baseline.conf
%{_libexecdir}/client-baseline/configure-observability-client

%changelog
* Sun Sep 13 2026 Infrastructure Platform <root@localhost> - 1.2.8-1
- Remove runuser-based Alloy validation; hardened Git Deploy contexts may not have CAP_SETGID
- Validate syntax as deployment user, install root:root 0644, then verify real service-user runtime via systemd stability check

* Sun Sep 13 2026 Infrastructure Platform <root@localhost> - 1.2.7-1
- SUSE-safe discovery of configure-observability-client is handled by the deployment installer; keep 0644 Alloy config and stable runtime validation

* Sun Sep 13 2026 Infrastructure Platform <root@localhost> - 1.2.6-1
- Make /etc/alloy/config.alloy root:root 0644; config contains no secrets and must be readable by the effective Alloy service user
- Keep observability credentials only in the protected EnvironmentFile

* Sun Sep 13 2026 Infrastructure Platform <root@localhost> - 1.2.5-1
- Harden Alloy configuration generation: plain endpoint URLs only, correct Alloy // comments, actual service user for journal groups
- Add stable source=alloy and job=systemd-journal labels for Loki queries

* Sun Sep 13 2026 Infrastructure Platform <root@localhost> - 1.2.4-1
- Harden Alloy service-account repair: parse effective Unit User/Group, fallback to alloy, verify account before start, reset failed state
- Keep Alloy runtime start/restart exclusively in observability-client/install.sh; RPM transaction only reloads systemd

* Sun Sep 13 2026 Infrastructure Platform <root@localhost> - 1.2.3-1
- Repair missing Alloy system user/group before runtime validation; prevent systemd 217/USER and own /var/lib/alloy correctly

* Sun Sep 13 2026 Infrastructure Platform <root@localhost> - 1.2.2-1
- Make Alloy config readable by the real service group; validate as service user; runtime stability check with journal diagnostics
- Keep product-specific deployment logic in observability-client/install.sh instead of swallowing configuration errors in RPM postinstall

* Sun Sep 13 2026 Infrastructure Platform <root@localhost> - 1.2.1-1
- Fix Grafana Alloy comment syntax and validate atomically before activating config

* Sat Sep 12 2026 Infrastructure Platform <root@localhost> - 1.2.0-1
- Package-owned Alloy configuration and service activation; no Git install script required

* Sat Sep 12 2026 Infrastructure Platform <root@localhost> - 1.1.0-1
- Generic meta-package and drop-in names

* Sat Sep 12 2026 Infrastructure Platform <root@localhost> - 1.0.0-1
- Initial meta package
