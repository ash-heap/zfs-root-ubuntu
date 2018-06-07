#!/bin/bash

# Install Ubuntu (and Ubuntu based distributions) onto a ZFS ROOT.  Only single
# disk or mirrored configurations are currently supported (multiple VDEV's are
# not currently supported).  MBR booting is not supported, the system must boot
# in UEFI mode.
#
# This is heavily based on:
# https://github.com/zfsonlinux/zfs/wiki/Ubuntu-18.04-Root-on-ZFS
# https://github.com/zfsonlinux/pkg-zfs/wiki/HOWTO-install-Ubuntu-18.04-to-a-Whole-Disk-Native-ZFS-Root-Filesystem-using-Ubiquity-GUI-installer


# Version (change these to support different versions)
VERSION=18.04
RELEASE=bionic
INSTALLER="ubiquity --no-bootloader"

# Settings
DEBUG=1  # 0 to actually run commands, 1 to log commands to zfs_root.log
LOGFILE=install.log
rm -f "$LOGFILE"

# Result Variables (and defaults)
USERNAME="localadmin"
RPOOL="rpool"
FILESYSTEMS=()
SWAP=""
DISKS=()
TYPE=desktop

CHANGES=0
RESULTS="$(mktemp)"


function release() {
    lsb_release -a | awk -F: '$1 == "Description"{print $2}' | awk '{$1=$1};1'
}
BACKTITLE="Installing $(release) on ZFS ROOT pool..."


function finish {
    clear
    rm "$RESULTS"
}
trap finish EXIT


function ctrl_c {
    cancel
    finish
}
trap ctrl_c INT


function cmd {
    echo "$@" >>"$LOGFILE"
    if [[ "$DEBUG" -eq 0 ]]; then
        $(echo "$@") >>"$LOGFILE" 2>&1 
        echo "" >> "$LOGFILE"
    fi
}


function append {
    echo "echo -e \"$1\" >> \"$2\"" >>"$LOGFILE"
    if [[ "$DEBUG" -eq 0 ]]; then
        echo -e "$1" >> "$2"
    fi
}


function overwrite {
    echo "echo -e \"$1\" > \"$2\"" >>"$LOGFILE"
    if [[ "$DEBUG" -eq 0 ]]; then
        echo -e "$1" > "$2"
    fi
}


function info() {
    dialog \
        --backtitle "$BACKTITLE"  \
        --infobox "$1" 3 70;
    sleep 2 # ensures the info is displayed long enough for the user to read it
}


function cancel {
    if [[ "$CHANGES" == 0 ]]; then
        msg="No changes made to disk."
    else
        msg="Disk is in an unknown state."
    fi
    dialog \
        --title "Installation Canceled" \
        --backtitle "$BACKTITLE"  \
        --msgbox "$msg" 6 40
    exit 0;
}


function init {
    cmd apt-add-repository universe
    cmd apt update
    cmd apt install --yes dialog
    info "Installing dependencies..."
    cmd apt install --yes gdisk zfs-initramfs mdadm vim dosfstools grub-pc
}


function get_install_type() {
    msg="Select "
    dialog \
        --title "Installation Type" \
        --backtitle "$BACKTITLE" \
        --menu "$msg" \
        9 70 2 \
        "desktop" "Desktop installation with GNOME Shell." \
        "server" "Server installation." \
        2>"$RESULTS"
    EXIT=$?
    if [[ "$EXIT" -ne 0 ]]; then
        cancel
    fi
    TYPE="$(<"$RESULTS")"
}


function list_ethernets() {
    ip link | awk -F: '$2 ~ "en"{print $2}' | awk '{$1=$1};1'
}


function get_network() {
    if [[ "$TYPE" != "desktop" ]]; then
        local ethernets=()
        for eth in $(list_ethernets); do
            id=$(disk_id "$sdx")
            ethernets+=("$eth")
            ethernets+=("$eth")
        done
        msg="Because this is a '$TYPE' installation, NetworkManager will not "
        msg+="manage the interfaces.  Select an interface to be initialized "
        msg+="with DHCP (can be changed after install by editing "
        msg+="'/etc/netplan/01-netcdf.yaml'):"
        dialog \
            --title "Select Root Drives" \
            --backtitle "$BACKTITLE" \
            --notags \
            --menu "$msg" \
            $((10+${#ethernets[@]}/2)) 70 $((${#ethernets[@]}/2)) "${ethernets[@]}" \
            2>"$RESULTS"
        EXIT=$?
        if [[ "$EXIT" -ne 0 ]]; then
            cancel
        fi
        local eth
        eth="$(<"$RESULTS")"
        cat << EOF > 01-netcdf.yaml
# This file describes the network interfaces available on your system
# For more information, see netplan(5).
network:
  version: 2
  renderer: networkd
  ethernets:
    $eth:
      dhcp4: yes
      dhcp6: yes

EOF
    fi
}


function get_username() {
    msg="Specify username of the first user (UID=1000):"
    dialog \
        --title "Username" \
        --backtitle "$BACKTITLE"  \
        --inputbox "$msg" 8 70 "$USERNAME" 2>"$RESULTS"
    EXIT=$?
    if [[ "$EXIT" -ne 0 ]]; then
        cancel
    fi
    USERNAME="$(<"$RESULTS")"
    while [[ ("$USERNAME" == "") || ("$USERNAME" =~ [^a-zA-Z0-9]) ]]; do
        msg="Usernames must consists only of alphanumeric strings "
        msg+="without spaces.\\n\\n"
        msg+="Specify username of the first user (UID=1000):"
        dialog \
            --title "Username" \
            --backtitle "$BACKTITLE"  \
            --inputbox "$msg" 11 70 "$USERNAME" 2>"$RESULTS"
        EXIT=$?
        if [[ "$EXIT" -ne 0 ]]; then
            cancel
        fi
        USERNAME=$(<"$RESULTS")
    done
}


function get_rpool_name() {
    msg="While \"rpool\" is standard among automated installation's you may "
    msg+="whish to use the hostname instead.\\n\\n"
    msg+="Specify the name of the ROOT ZFS pool:"
    dialog \
        --title "ROOT Pool Name" \
        --backtitle "$BACKTITLE"  \
        --inputbox "$msg" 11 70 "$RPOOL" 2>"$RESULTS"
    EXIT=$?
    if [ "$EXIT" -ne 0 ]; then
        cancel
    fi
    RPOOL="$(<"$RESULTS")"
    while [[ ("$RPOOL" == "") || ("$RPOOL" =~ [^a-zA-Z0-9]) ]]; do
        msg="Pool names must consists only of alphanumeric strings "
        msg+="without spaces.\\n\\n"
        msg+="Specify the name of the ROOT ZFS pool:"
        dialog \
            --title "ROOT Pool Name" \
            --backtitle "$BACKTITLE"  \
            --inputbox "$msg" 11 70 "$RPOOL" 2>"$RESULTS"
        EXIT=$?
        if [[ "$EXIT" -ne 0 ]]; then
            cancel
        fi
        RPOOL=$(<"$RESULTS")
    done
}


get_filesystems() {
    msg="Select which directories you want separate ZFS filesystems for."
    dialog \
        --title "Optional Filesystems" \
        --backtitle "$BACKTITLE" \
        --separate-output \
        --checklist "$msg" \
        17 70 9 \
        "local" "/usr/local" ON \
        "opt" "/opt" ON \
        "srv" "/var/srv" OFF \
        "games" "/var/games" OFF \
        "mongodb" "/var/lib/mongodb" OFF \
        "mysql" "/var/lib/mysql" OFF \
        "postgres" "/var/lib/postgres" OFF \
        "nfs" "/var/lib/nfs" OFF \
        "mail" "/var/mail" ON \
        2>"$RESULTS"
    EXIT=$?
    if [[ "$EXIT" -ne 0 ]]; then
        cancel
    fi
    mapfile -t FILESYSTEMS < "$RESULTS"
}


function get_swap() {
    msg="Do you want a swap partition?\\n\\n"
    msg+="This will be a a ZVOL on the ROOT pool."
    dialog \
        --title "Swap File" \
        --backtitle "$BACKTITLE"  \
        --yesno "$msg" 7 70
    EXIT=$?
    if [[ "$EXIT" -eq 0 ]]; then
        get_swap_size
        return 0
    elif [[ "$EXIT" -eq 1 ]]; then
        return 0
    else
        cancel
    fi
}


# print memory in MiB
function get_ram() {
    free --mebi | awk '$1 ~ "Mem"{print $2}'
}


function recomended_swap() {
    # based on https://askubuntu.com/a/49138
    local mem
    mem=$(get_ram)
    if [[ "$mem" -le 2024 ]]; then
        echo "$((mem*2))M"
    elif [[ "$mem" -le 8192 ]]; then
        echo "$((mem/1024))G"
    elif [[ "$mem" -le 16384 ]]; then
        echo "8G"
    else
        echo "$((mem/2/1024))G"
    fi
}


function get_swap_size() {
    msg="This should be less than the total pool size.  "
    msg+="The value below is the recommeded swap size.\\n\\n"
    msg+="Specify desired swap size in mebibytes (M) or gibibytes (G):"
    dialog \
        --title "Swap Size" \
        --backtitle "$BACKTITLE"  \
        --inputbox "$msg" 11 70 "$(recomended_swap)" 2>"$RESULTS"
    EXIT=$?
    if [[ "$EXIT" -ne 0 ]]; then
        cancel
    fi
    SWAP="$(<"$RESULTS")"
    while ! [[ "$SWAP" =~ ^[1-9][0-9]*[mMgG]$ ]]; do
        msg="Invalid format!\\n\\n"
        msg+="This should be less than the total pool size.\\n\\n"
        msg+="Specify desired swap size in megabytes (M) or gigabytes (G):"
    dialog \
        --title "Swap Size" \
        --backtitle "$BACKTITLE"  \
        --inputbox "$msg" 12 70 "$SWAP" 2>"$RESULTS"
        EXIT=$?
        if [[ "$EXIT" -ne 0 ]]; then
            cancel
        fi
        SWAP=$(<"$RESULTS")
    done
}


function list_disks() {
    lsblk --noheadings --output TYPE,NAME | awk '$1 == "disk"{print $2}'
}


function disk_id() {
    find /dev/disk/by-id -name '*' \
        -exec echo -n {}" " \; -exec readlink -f {} \; | \
        awk -v sdx="$1" \
        '($2 ~ sdx"$") && ($1 !~ "wwn|eui|ieee"){print $1}'
    }


function disk_size() {
    lsblk "/dev/$1" --noheadings --output SIZE | head -n 1
}


function get_rpool_disks() {
    DISKS=()
    for sdx in $(list_disks); do
        id=$(disk_id "$sdx")
        DISKS+=("$sdx")
        DISKS+=("$(printf "%3s  %6s  %s" "$sdx" "$(disk_size "$sdx")" "$(echo "$id" | cut -c1-40)")")
        DISKS+=(OFF)
    done
    msg="Select disks to use for the root pool.  "
    msg+="Only single disk and mirrored configurations are supported at "
    msg+="this time.  ALL DATA on chosen disks will be LOST."
    dialog \
        --title "Select Root Drives" \
        --backtitle "$BACKTITLE" \
        --notags --separate-output \
        --checklist "$msg" \
        $((5+${#DISKS[@]})) 70 ${#DISKS[@]} "${DISKS[@]}" 2>"$RESULTS"
    EXIT=$?
    if [[ "$EXIT" -ne 0 ]]; then
        cancel
    fi
    mapfile -t DISKS < "$RESULTS"
    if [[ "${#DISKS[@]}" -eq 0 ]]; then
        msg="No disks where selected.  "
        msg+="Would you like to cancel the installation?"
        dialog \
            --title "No Drives Selected" \
            --backtitle "$BACKTITLE"  \
            --yesno "$msg" 7 70
        EXIT=$?
        if [[ "$EXIT" -eq 1 ]]; then
            get_rpool_disks
            return 0
        else
            cancel
        fi
    fi
}


function prepare_disk() {
    cmd mdadm --zero-superblock --force "$1"
    cmd sgdisk --zap-all "$1"
    cmd sgdisk -n3:1M:+512M -t3:EF00 "$1"
    cmd sgdisk -n1:0:0 -t1:BF01 "$1"
}


function create_rpool() {
    if [[ "${#DISKS[@]}" -eq 1 ]]; then
        local sdx=${DISKS[0]}
        local size
        local id
        id=$(disk_id "$sdx")
        size=$(disk_size "$sdx")
        msg="WARNING: All data will be lost on disk:\\n\\n"
        msg+="    "
        msg+=$(printf "%3s  %6s  %s" "$sdx" "$size" "$id")
        msg+="\\n\\n"
        msg+="WARNING: Single disk layouts do not have any redundancy "
        msg+="against disk failures or file corruption.\\n\\n"
        msg+="Do you wish to proceed?"
        if dialog \
            --title "WARNING: DATA LOSS" \
            --backtitle "$BACKTITLE"  \
            --defaultno \
            --yesno "$msg" 13 70;
        then
            info "Partitioning drive..."
            CHANGES=1
            prepare_disk "$id"
            cmd sleep 5
            info "Creating ZFS pool..."
            cmd zpool create -f -o ashift=12 \
              -O atime=off -O canmount=off -O compression=lz4 \
              -O normalization=formD -O xattr=sa -O mountpoint=/ -R /mnt \
              "$RPOOL" "$id-part1"
        else
            cancel
        fi
    else
        msg="WARNING: All data will be lost on disks:\\n\\n"
        for sdx in "${DISKS[@]}"; do
            local id
            id=$(disk_id "$sdx")
            msg+="    "
            msg+=$(printf "%3s  %6s  %s" "$sdx" "$(disk_size "$sdx")" "$id")
            msg+="\\n"
        done
        msg+="\\n"
        msg+="Do you wish to proceed?"
        if dialog \
            --title "WARNING: DATA LOSS" \
            --backtitle "$BACKTITLE"  \
            --defaultno \
            --yesno "$msg" $((8+2*${#DISKS[@]})) 70;
        then
            CHANGES=1
            info "Partitioning drives..."
            local partitions=()
            for disk in "${DISKS[@]}"; do
                local id
                id=$(disk_id "$sdx")
                prepare_disk "$id"
                partitions+=("$id""-part1")
            done
            cmd sleep 5
            info "Creating ZFS pool..."
            cmd zpool create -f -o ashift=12 \
              -O atime=off -O canmount=off -O compression=lz4 \
              -O normalization=formD -O xattr=sa -O mountpoint=/ -R /mnt \
              "$RPOOL" mirror "${partitions[@]}"
        else
            cancel
        fi
    fi
}


function create_filesystems() {
    info "Creating filesystems..."

    # / and root
    cmd zfs create -o canmount=off -o mountpoint=none "$RPOOL/ROOT"
    cmd zfs create -o canmount=noauto -o mountpoint=/ "$RPOOL/ROOT/ubuntu"
    cmd zfs mount "$RPOOL/ROOT/ubuntu"
    cmd zfs create -o setuid=off "$RPOOL/home"
    cmd zfs create -o mountpoint=/root "$RPOOL/home/root"

    # first user home
    cmd zfs create "$RPOOL/home/$USERNAME"
    cmd zfs create -o com.sun:auto-snapshot=false "$RPOOL/home/$USERNAME/.cache"
    cmd zfs create -o com.sun:auto-snapshot=false "$RPOOL/home/$USERNAME/Downloads"
    cmd zfs create -o com.sun:auto-snapshot=false "$RPOOL/home/$USERNAME/Scratch"
    cmd chown -R 1000:1000 "/mnt/home/$USERNAME"

    # var
    cmd zfs create -o canmount=off -o setuid=off -o exec=off "$RPOOL"/var
    cmd zfs create -o com.sun:auto-snapshot=false "$RPOOL"/var/cache
    cmd zfs create -o acltype=posixacl -o xattr=sa "$RPOOL"/var/log
    cmd zfs create -o com.sun:auto-snapshot=false "$RPOOL"/var/spool
    cmd zfs create -o com.sun:auto-snapshot=false exec=on "$RPOOL"/var/tmp

    # optional filesystems
    for option in "${FILESYSTEMS[@]}"; do
        case "$option" in
            local)
                cmd zfs create -o canmount=off "$RPOOL/usr"
                cmd zfs create "$RPOOL/usr/local"
                ;;
            opt)
                cmd zfs create "$RPOOL/opt"
                ;;
            srv)
                cmd zfs create -o setuid=off -o exec=off "$RPOOL/srv"
                ;;
            games)
                cmd zfs create -o exec=on "$RPOOL/games"
                ;;
            mongodb)
                cmd zfs create -o mountpoint=/var/lib/mongodb \
                    "$RPOOL/var/mongodb"
                ;;
            mysql)
                cmd zfs create -o mountpoint=/var/lib/mysql \
                    "$RPOOL/var/mysql"
                ;;
            postgres)
                cmd zfs create -o mountpoint=/var/lib/postgres \
                    "$RPOOL/var/postgres"
                ;;
            nfs)
                cmd zfs create -o mountpoint=/var/nfs \
                    -o com.sun:auto-snapshot=false -o "$RPOOL"/var/nfs
                ;;
            mail)
                cmd zfs create "$RPOOL/var/mail"
                ;;
        esac
    done

    # EFI partition(s)
    for sdx in "${DISKS[@]}"; do
        local id
        id=$(disk_id "$sdx")
        cmd mkdosfs -F 32 -n EFI "$id-part3"
    done
    cmd mkdir -p /mnt/boot/efi
    cmd mount "$(disk_id "${DISKS[0]}")-part3" /mnt/boot/efi

    # ubiquity install target
    cmd zfs create -V 10G "$RPOOL/target"

    # swap space
    if [[ "$SWAP" != "" ]]; then
        cmd zfs create -V "$SWAP" -b "$(getconf PAGESIZE)" -o compression=zle \
            -o logbias=throughput -o sync=always \
            -o primarycache=metadata -o secondarycache=none \
            -o com.sun:auto-snapshot=false "$RPOOL/swap"
        cmd mkswap -f "/dev/zvol/$RPOOL/swap"
    fi
}


function run_installer() {
    msg="The next step will launch the Ubiquity installer to install Ubuntu "
    msg+="to a temporary ZVOL.  You must follow the steps below, which may "
    msg+="not be visible once you select 'Launch Ubiquity'.\\n\\n"
    msg+="1. Select any options you like until you get to 'Installation \\n"
    msg+="   Type'.\\n\\n"
    msg+="2. Choose 'Erase disk and install Ubuntu'.\\n\\n"
    local disk
    disk=$(readlink -f "/dev/zvol/$RPOOL/target")
    msg+="3. Select '$disk' as the installation disk.\\n\\n"
    msg+="4. Continue selecting any options you like until you get to \\n"
    msg+="   'Who are you?'\\n\\n"
    local i=5
    if [[ "$RPOOL" != "rpool" ]]; then
        msg+="5. Type '$RPOOL' into 'Your computer's name:'.\\n\\n"
        i=$((i + 1))
    fi
    msg+="$i. Type '$USERNAME' into 'Pick a username:', \\n"
    msg+="   remembering that case matters.\\n\\n"
    i=$((i + 1))
    msg+="$i. All other options are up to you.\\n\\n"
    i=$((i + 1))
    msg+="$i. When a message appears that says 'Installation Complete' choose\\n"
    msg+="   'Continue Testing'.\\n"
    dialog \
        --title "Running the Ubiquity Installer" \
        --backtitle "$BACKTITLE"  \
        --yes-label "Launch Ubiquity" \
        --no-label "Cancel" \
        --yesno "$msg" 18 70
    EXIT=$?
    if [[ "$EXIT" -eq 0 ]]; then
        cmd "$INSTALLER"
        return 0
    else
        cancel
    fi
}


function copy_installation() {
    info "Copying installation to ZFS filesystems..."
    cmd rsync -avX /target/. /mnt/.
    append "RESUME=none" /etc/initramfs-tools/conf.d/resume
}


function install_fstab() {
    local fstab
    local efi_uuid
    fstab="/mnt/etc/fstab"
    efi_uuid=$(blkid -s PARTUUID -o value "$(disk_id "${DISKS[0]}")-part3")
    if [[ "$DEBUG" -eq 1 ]]; then
        fstab="./fstab"
        efi_uuid="EFI_UUID"
    fi
    cat << EOF > "$fstab"
# /etc/fstab: static fiel system information.
#
# Use 'blkid' to prin the universally unique identifer for a
# device; this may be used with UUID= as a more robust way t o name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>

$efi_uuid  /boot/efi  vfat nofaile,x-systemd.device-timeout=1  0  1

# Legacy mounts to avoid race conditions between ZFS and systemd.
$RPOOL/var/log  /var/log  zfs  defaults  0  0
$RPOOL/var/tmp  /var/tmp  zfs  defaults  0  0

/dev/zvol/$RPOOL/swap  none  swap  defaults  0  0
EOF
}


function install_netcfg() {
    cmd cp 01-netcfg.yaml /mnt/etc/netplan/
}


function convert_desktop_to_server() {
    if [[ ("$TYPE" == "server") && ($DEBUG -eq 0) ]]; then
        info "Converting desktop installation to server installation..."
        cat << EOF | chroot /mnt
apt update
apt purge --yes ubuntu-desktop
apt autoremove --yes
apt install --yes ubuntu-server
EOF
    fi
}


function install_zfs_initramfs() {
    info "Installing ZFS initramfs..."
    if [[ ($DEBUG -eq 0) ]]; then
        cat << EOF | chroot /mnt
apt-add-repository universe
apt update
apt install --yes zfs-initramfs
EOF
    fi
}


function install_grub() {
    info "Installing GRUB bootloader..."
    if [[ ($DEBUG -eq 0) ]]; then
        cat << EOF | chroot /mnt
apt update
apt install --yes grub-efi-amd64
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=ubuntu --recheck --no-floppy
EOF
    fi
}


function chroot() {
    info "Chrooting into installation for final configuration..."
    cmd mount --rbind /dev  "$1/dev"
    cmd mount --rbind /proc "$1/proc"
    cmd mount --rbind /sys  "$1/sys"
    append "nameserver 8.8.8.8" "$1/etc/resolv.conf"
    convert_desktop_to_server
    install_zfs_initramfs
    install_grub
}


function clone_efi() {
    if [[ "${#DISKS[@]}" -gt 1 ]]; then
        info "Cloning EFI parition to each drive..."
        local i=1
        cmd umount /mnt/boot/efi
        for disk in "${DISKS[@]:1}"; do
            cmd dd if="$(disk_id "${DISKS[0]}")-part3" \
                of="$(disk_id "$disk")-part3"
            cmd efibootmgr -c -g -d "$(disk_id "${DISKS[0]}")" \
                -p 3 -L "ubuntu-$i" -l '\EFI/Ubuntu\grubx64.efi'
            i=$((i+1))
        done
        cmd mount "$(disk_id "${DISKS[0]}")-part3" /mnt/boot/efi
    fi
}


function finalize() {
    msg="Make any other customizations to the system at '/mnt' in another "
    msg+="terminal before selecting 'Continue'.\\n\\n"
    dialog \
        --title "Customizations" \
        --backtitle "$BACKTITLE"  \
        --ok-label "Continue" \
        --msgbox "$msg" 6 70
    EXIT=$?
    cmd zfs snapshot "$RPOOL/ROOT/ubuntu@install"
    cmd umount -R /mnt
    cmd swapoff -a
    cmd umount /target
    cmd zpool export "$RPOOL"
    msg="Do you want to reboot into your new installation now?\\n\\n"
    dialog \
        --title "Swap File" \
        --backtitle "$BACKTITLE"  \
        --yesno "$msg" 5 70
    EXIT=$?
    if [[ "$EXIT" -eq 0 ]]; then
        cmd reboot
        return 0
    else
        return 0
    fi
}


init
get_install_type
get_network
get_username
get_rpool_name
get_filesystems
get_swap
get_rpool_disks
create_rpool
create_filesystems
run_installer
copy_installation
install_fstab
install_netcfg
chroot
clone_efi
finalize
