#
# Developer support: allow local install
#
# note: keep in sync with package maintainer origin:
# https://git.archlinux.org/svntogit/community.git/tree/trunk/PKGBUILD?h=packages/mkinitcpio-systemd-tool
#
# manual package build and install steps:
# * cd "$this_repo"
# * rm -r -f  pkg/ *.pkg.tar.zst
# * makepkg -e
# * sudo pacman -U *.pkg.tar.zst
#

pkgname=mkinitcpio-systemd-tool
pkgver=build
pkgrel=$(date +%s)
pkgdesc="Provisioning tool for systemd in initramfs (systemd-tool)"
arch=('any')
url="https://github.com/random-archer/mkinitcpio-systemd-tool"
license=('Apache')
depends=('mkinitcpio' 'systemd' 'busybox' 'curl' 'ca-certificates-utils')
optdepends=('cryptsetup: for initrd-cryptsetup.service'
            'dropbear: for initrd-dropbear.service'
            'mc: for initrd-debug-progs.service'
            'nftables: for initrd-nftables.service'
            'tinyssh: for initrd-tinysshd.service'
            'tinyssh-convert: for initrd-tinysshd.service'
            'ppp: for initrd-ppp.service'
            'frpc: for initrd-frpc.service'
            'ddns-go: for initrd-ddns-go.service')
conflicts=('mkinitcpio-dropbear' 'mkinitcpio-tinyssh')
backup=("etc/${pkgname}/config/crypttab"
        "etc/${pkgname}/config/fstab"
        "etc/${pkgname}/config/ntp.conf"
        "etc/${pkgname}/config/initrd-nftables.conf"
        "etc/${pkgname}/config/initrd-shell.conf"
        "etc/${pkgname}/config/initrd-util-usb-hcd.conf"
        "etc/${pkgname}/network/initrd-network.network" )
#source=("$pkgname-$pkgver.tar.gz::https://github.com/random-archer/${pkgname}/archive/v${pkgver}.tar.gz")
#install="${pkgname}.install"
#sha512sums=()

package() {
  cd ..
  make DESTDIR="$pkgdir/" PREFIX='/usr' install
}
