Name:           monit-prometheus-exporter
Version:        1.1.0
Release:        1%{?dist}
Summary:        Monit XML to Prometheus exporter for managed hosts
License:        Proprietary
BuildRequires:  systemd-rpm-macros
BuildArch:      x86_64
Requires:       monit
Provides:       teko-monit-exporter = %{version}-%{release}
Obsoletes:      teko-monit-exporter < 1.1.0

%description
Local loopback-only Prometheus exporter for Monit XML status. Credentials are
read from the Config Agent runtime secret and are never packaged.

%prep

%build

%install
install -D -m 0755 %{_sourcedir}/monit-prometheus-exporter-linux-amd64 %{buildroot}%{_bindir}/monit-prometheus-exporter
install -D -m 0644 %{_sourcedir}/monit-prometheus-exporter.service %{buildroot}%{_unitdir}/monit-prometheus-exporter.service

%post
%systemd_post monit-prometheus-exporter.service

%preun
%systemd_preun monit-prometheus-exporter.service

%postun
%systemd_postun_with_restart monit-prometheus-exporter.service


%posttrans
# Remove the legacy hand-written unit from pre-3.16.1 installations.
if [ -f /etc/systemd/system/teko-monit-exporter.service ]; then
  systemctl disable --now teko-monit-exporter.service >/dev/null 2>&1 || :
  rm -f /etc/systemd/system/teko-monit-exporter.service
fi
systemctl daemon-reload >/dev/null 2>&1 || :

%files
%{_bindir}/monit-prometheus-exporter
%{_unitdir}/monit-prometheus-exporter.service

%changelog
* Sat Sep 12 2026 Infrastructure Platform <root@localhost> - 1.1.0-1
- Generic package, service, binary and metric names

* Sat Sep 12 2026 Infrastructure Platform <root@localhost> - 1.0.0-1
- Initial packaged exporter
