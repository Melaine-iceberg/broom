# Binary RPM for the prebuilt Flutter bundle and the Polkit helper.
#
# This is intentionally not a from-source Fedora package: Flutter and the
# helper are built by tool/package_rpm.sh, then this spec only installs the
# staged bundle. Keep the helper path in sync with
# PkexecLinuxSystemMaintenance.defaultHelperPath.
%global debug_package %{nil}
%global __os_install_post %{nil}
%{!?broom_version:%global broom_version 0.0.0}

Name:           broom
Version:        %{broom_version}
Release:        1%{?dist}
Summary:        Safe, reversible cache cleaner for Linux desktops

# Placeholder until the repository has a LICENSE file. Replace before any
# public distribution.
License:        Proprietary
URL:            https://melaine-iceberg.github.io/broom/
Source0:        broom-bundle-%{version}.tar.gz
BuildArch:      x86_64
AutoReqProv:    no

Requires:       polkit
Requires:       systemd
Requires:       gtk3
Requires:       glib2
Requires:       libstdc++
Requires:       xz-libs

%description
Broom scans declared cache locations, previews results, and moves files to a
quarantine so a clean can be undone. The optional system helper cleans APT or
DNF package caches and the systemd journal after one Polkit authorization.

%prep
%setup -q -n broom-bundle-%{version}

%build
# The Flutter bundle and the system helper are built before rpmbuild runs.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}%{_libdir}/broom
cp -a bundle/. %{buildroot}%{_libdir}/broom/
install -Dm0755 helper/broom-system-helper \
  %{buildroot}%{_libexecdir}/broom/broom-system-helper
install -Dm0644 packaging/broom.desktop \
  %{buildroot}%{_datadir}/applications/broom.desktop
install -Dm0644 packaging/broom.png \
  %{buildroot}%{_datadir}/icons/hicolor/1024x1024/apps/broom.png
install -Dm0644 packaging/com.broom.Broom.policy \
  %{buildroot}%{_datadir}/polkit-1/actions/com.broom.Broom.policy
mkdir -p %{buildroot}%{_bindir}
ln -sf "$(realpath --relative-to=%{buildroot}%{_bindir} %{buildroot}%{_libdir}/broom/broom)" \
  %{buildroot}%{_bindir}/broom

%files
%{_bindir}/broom
%{_libdir}/broom/
%{_datadir}/applications/broom.desktop
%{_datadir}/icons/hicolor/1024x1024/apps/broom.png
%{_libexecdir}/broom/broom-system-helper
%{_datadir}/polkit-1/actions/com.broom.Broom.policy
%doc README.md docs/linux-system-cache.md

%changelog
* Sat Oct 24 2026 Broom maintainers <maintainers@example.invalid> - %{version}-1
- Binary bundle with the Polkit system-cache helper
