#!/bin/bash

# Install Ubuntu (and Ubuntu based distributions) onto a ZFS ROOT.  Only single
# disk or mirrored configurations are currently supported (multiple VDEV's are
# not currently supported).  MBR booting is not supported, the system must boot
# in UEFI mode.

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
    echo "echo -e \"$1\" > \"$2\"" >>"$LOGFILE"
    if [[ "$DEBUG" -eq 0 ]]; then
        echo -e "$1" >> "$2"
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
    info "Installing dependencies..."
    cmd apt-add-repository universe
    cmd apt update
    cmd apt install --yes gdisk zfs-initramfs mdadm dialog dosfstools grub-pc
}


function get_install_type() {
    msg="Select "
    dialog \
        --title "Installation Type" \
        --backtitle "$BACKTITLE" \
        --menu "$msg" \
        17 70 3 \
        "minimal" "A minimal command line install." \
        "server" "Server installation." \
        "desktop" "Desktop installation using GNOME Shell" \
        2>"$RESULTS"
    EXIT=$?
    if [[ "$EXIT" -ne 0 ]]; then
        cancel
    fi
    TYPE="$(<"$RESULTS")"
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
        local id
        id=$(disk_id "$sdx")
        local size
        size=$(disk_size "$sdx")
        msg="WARNING: All data will be lost on disk:\\n\\n"
        msg+="    "
        msg+=$(printf "%3s  %6s  %s" "$sdx" "$(disk_size "$sdx")" "$id")
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
    cmd zfs create -o canmount=off -o mountpoint=none "$RPOOL"/ROOT
    cmd zfs create -o canmount=noauto -o mountpoint=/ "$RPOOL"/ROOT/ubuntu
    cmd zfs mount "$RPOOL"/ROOT/ubuntu
    cmd zfs create -o setuid=off "$RPOOL"/home
    cmd zfs create -o mountpoint=/root "$RPOOL"/home/root

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
                cmd zfs create -o canmount=off "$RPOOL/var/lib"
                cmd zfs create "$RPOOL/var/mongodb"
                ;;
            mysql)
                cmd zfs create -o canmount=off "$RPOOL/var/lib"
                cmd zfs create "$RPOOL/var/mysql"
                ;;
            postgres)
                cmd zfs create -o canmount=off "$RPOOL/var/lib"
                cmd zfs create "$RPOOL/var/postgres"
                ;;
            nfs)
                cmd zfs create -o canmount=off "$RPOOL/var/lib"
                cmd zfs create -o com.sun:auto-snapshot=false -o \
                    "$RPOOL"/var/nfs
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
    cmd mkdir /mnt/boot
    cmd mount "$(disk_id "${DISKS[0]}")" /mnt/boot

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
    msg+="to a temporary ZVOL.  You must follow the steps below:\\n\\n"
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
    if [[ "$DEBUG" -eq 1 ]]; then
        cmd rsync -avX /target/. /mnt/.
        for i in {1..100}; do
            sleep 0.1
            echo $i
        done | dialog \
        --title "Installing" \
        --backtitle "$BACKTITLE"  \
        --gauge "Copying installation to ZFS filesystems..." 7 70
    else
        local total=$(($(rsync -avXn /target/. /mnt/. | wc -l) - 3))
        echo "rsync -avX /target/. /mnt/." >> "$LOGFILE"
        local n=0
        cmd rsync -avX /target/. /mnt/.
    fi
}


function build_fstab() {
    local efi_uuid
    efi_uuid=$(blkid -s PARTUUID -o value "$(disk_id "${DISKS[0]}")-part3")
    if [[ "$DEBUG" -eq 1 ]]; then
        efi_uuid="EFI_UUID"
    fi
    cat << EOF > /mnt/etc/fstab
# /etc/fstab: static fiel system information.
#
# Use 'blkid' to prin the universally unique identifer for a
# device; this may be used with UUID= as a more robust way t o name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>

$efi_uuid  /boot/efi  vfat nofaile,x-systemd.device-timeout=1  0  1

# Legacy mount /var/log and /var/tmp to avoid race coditions with systemd.
$RPOOL/var/log  /var/log  zfs  defaults  0  0
$RPOOL/var/tmp  /var/tmp  zfs  defaults  0  0

/dev/zvol/$RPOOL/swap  none  swap  defaults  0  0
EOF
}




init
get_install_type
get_username
get_rpool_name
get_filesystems
get_swap
get_rpool_disks
create_rpool
create_filesystems
run_installer
copy_installation
