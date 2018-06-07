#!/bin/bash

cmd mount --rbind /dev  "$1/dev"
cmd mount --make-rslave "$1/dev"
cmd mount --rbind /proc "$1/proc"
cmd mount --make-rslave "$1/proc"
cmd mount --rbind /sys  "$1/sys"
cmd mount --make-rslave "$1/sys"
append "nameserver 8.8.8.8" "$1/etc/resolv.conf"
cmd chroot "$@"
cmd umount -R "$1/dev"
cmd umount -R "$1/proc"
cmd umount -R "$1/sys"
