#!/bin/sh
#

#
# these properties are available for customization
#
ROOTPOOL="rpool"
DRIVELIST=""
SWAPSIZE="2g"
ZFSARGS=""
BFLAG=""
REBOOT="no"
OVERLAYS=""
NODENAME=""
TIMEZONE=""

FSTYPE="ZFS"
DRIVE1=""
DRIVE2=""
PKGLOC="/.cdrom/pkgs"
SMFREPODIR="/usr/lib/zap"
ALTROOT="/a"

#
# read an external configuration file, if supplied
#
IPROFILE=`/sbin/devprop install_profile`
if [ ! -z "$IPROFILE" ]; then
REBOOT="yes"
case $IPROFILE in
nfs*)
	TMPMNT="/tmp/mnt1"
	mkdir -p ${TMPMNT}
	IPROFDIR=${IPROFILE%/*}
	IPROFNAME=${IPROFILE##*/}
	mount $IPROFDIR $TMPMNT
	if [ -f ${TMPMNT}/${IPROFNAME} ]; then
	    . ${TMPMNT}/${IPROFNAME}
	fi
	umount ${TMPMNT}
	rmdir ${TMPMNT}
	;;
http*)
	TMPF="/tmp/profile.$$"
	DELAY=0
	while [ ! -f "$TMPF" ]
	do
	    sleep $DELAY
	    DELAY=$(($DELAY+1))
	    /usr/bin/curl -f -s -S --retry 6 -o $TMPF $IPROFILE
	done
	. $TMPF
	rm -fr $TMPF
	;;
esac
fi

#
# interactive argument handling
#
while getopts "Bm:n:t:" opt; do
    case $opt in
        B)
	    BFLAG="-B"
	    ;;
        m)
	    ZFSARGS="mirror"
	    DRIVE2="$OPTARG"
	    ;;
        n)
	    NODENAME="$OPTARG"
	    ;;
        t)
	    TIMEZONE="$OPTARG"
	    ;;
    esac
done
shift $((OPTIND-1))

#
# the first remaining argument is a drive to install to
#
case $# in
0)
	printf ""
	;;
*)
	DRIVE1=$1
	shift
	;;
esac

#
# everything else is an overlay
#
OVERLAYS="$OVERLAYS $*"

#
# if we have a drive list at this point, it must be from cardigan, 
# so check the list for validity
#
if [ -n "$DRIVELIST" ]; then
  for TDRIVE in $DRIVELIST
  do
    if [ ! -e /dev/dsk/$TDRIVE ]; then
      if [ ! -e /dev/dsk/${TDRIVE}s0 ]; then
        echo "ERROR: Unable to find supplied device $TDRIVE"
        exit 1
      fi
    fi
  done
fi

#
# verify drives are valid
#

if [ -n "$DRIVE1" ]; then
    if [ ! -e /dev/dsk/$DRIVE1 ]; then
	if [ -e /dev/dsk/${DRIVE1}s0 ]; then
	    DRIVE1="${DRIVE1}s0"
	else
	    echo "ERROR: Unable to find device $DRIVE1"
	    exit 1
	fi
    fi
    DRIVELIST="$DRIVELIST $DRIVE1"
fi
if [ -n "$DRIVE2" ]; then
    if [ ! -e /dev/dsk/$DRIVE2 ]; then
	if [ -e /dev/dsk/${DRIVE2}s0 ]; then
	    DRIVE2="${DRIVE2}s0"
	else
	    echo "ERROR: Unable to find device $DRIVE2"
	    exit 1
	fi
    fi
    DRIVELIST="$DRIVELIST $DRIVE2"
fi

#
# end interactive argument handling
#

#
# if no drives are listed to install to, exit now
#
if [ -z "$DRIVELIST" ]; then
    echo "ERROR: no installation drives specified or found"
    echo "Usage: $0 [-B] [ -m device ] device [overlay ... ]"
    exit 1
fi

#
# if we were asked to fdisk the drive, do so
#
case $BFLAG in
-B)
FDRIVELIST=""
for FDRIVE in $DRIVELIST
do
# normalize drive name, replace slice by slice2 for fdisk and by s0 for zpool
case $FDRIVE in
*s?)
    NDRIVE=`echo $FDRIVE | /usr/bin/sed 's:s.$:s2:'`
    FDRIVE=$NDRIVE
    NDRIVE=`echo $FDRIVE | /usr/bin/sed 's:s.$:s0:'`
    ;;
*)
    NDRIVE="${FDRIVE}s0"
    FDRIVE="${FDRIVE}s2"
esac
    FDRIVELIST="$FDRIVELIST $NDRIVE"
    /root/format-a-disk.sh -B $FDRIVE
done
DRIVELIST="$FDRIVELIST"
;;
esac

#
# FIXME allow ufs
# FIXME allow svm
#
/usr/bin/mkdir -p ${ALTROOT}
echo "Creating root pool"
/usr/sbin/zpool create -f -o failmode=continue ${ROOTPOOL} $ZFSARGS $DRIVELIST

echo "Creating filesystems"
/usr/sbin/zfs create -o mountpoint=legacy ${ROOTPOOL}/ROOT
/usr/sbin/zfs create -o mountpoint=${ALTROOT} ${ROOTPOOL}/ROOT/tribblix
/usr/sbin/zpool set bootfs=${ROOTPOOL}/ROOT/tribblix ${ROOTPOOL}
/usr/sbin/zfs create -o mountpoint=${ALTROOT}/export ${ROOTPOOL}/export
/usr/sbin/zfs create ${ROOTPOOL}/export/home
/usr/sbin/zfs create -V ${SWAPSIZE} -b 4k ${ROOTPOOL}/swap
/usr/sbin/zfs create -V ${SWAPSIZE} ${ROOTPOOL}/dump

#
# this gives the initial BE a UUID, necessary for 'beadm list -H'
# to not show null, and for zone uninstall to work
#
/usr/sbin/zfs set org.opensolaris.libbe:uuid=`/usr/lib/zap/generate-uuid` ${ROOTPOOL}/ROOT/tribblix

echo "Copying main filesystems"
cd /
ZONELIB=""
if [ -d zonelib ]; then
    ZONELIB="zonelib"
fi
/usr/bin/find boot kernel lib platform root sbin usr etc var opt ${ZONELIB} -print -depth | cpio -pdm ${ALTROOT}
echo "Copying other filesystems"
/usr/bin/find boot -print -depth | cpio -pdm /${ROOTPOOL}

#
echo "Adding extra directories"
cd ${ALTROOT}
/usr/bin/ln -s ./usr/bin .
/usr/bin/mkdir -m 1777 tmp
/usr/bin/mkdir -p system/contract system/object proc mnt dev devices/pseudo
/usr/bin/mkdir -p dev/fd dev/rmt dev/swap dev/dsk dev/rdsk dev/net dev/ipnet
/usr/bin/mkdir -p dev/sad dev/pts dev/term dev/vt dev/zcons
/usr/bin/chgrp -R sys dev devices
cd dev
/usr/bin/ln -s ./fd/2 stderr
/usr/bin/ln -s ./fd/1 stdout
/usr/bin/ln -s ./fd/0 stdin
/usr/bin/ln -s ../devices/pseudo/dld@0:ctl dld
cd /

#
# add overlays, from the pkgs directory on the iso
# or an alternate location supplied by boot
#
# we create a zap config based on boot properties, should we copy that
# to the installed image as the highest priority repo? The problem
# there is that it will block all future updates
#
# give ourselves some swap to avoid /tmp exhaustion
# do it after copying the main OS as it changes the dump settings
#
swap -a /dev/zvol/dsk/${ROOTPOOL}/swap
LOGFILE="${ALTROOT}/var/sadm/install/logs/initial.log"
echo "Installing overlays" | tee $LOGFILE
/usr/bin/date | tee -a $LOGFILE
TMPDIR=/tmp
export TMPDIR
PKGMEDIA=`/sbin/devprop install_pkgs`
if [ -d ${PKGLOC} ]; then
    for overlay in base-extras $OVERLAYS
    do
	echo "Installing $overlay overlay" | tee -a $LOGFILE
	/usr/lib/zap/install-overlay -R ${ALTROOT} -s ${PKGLOC} $overlay | tee -a $LOGFILE
    done
elif [ -z "$PKGMEDIA" ]; then
    echo "No packages found, unable to install overlays"
else
    echo "${ALTROOT}/var/zap/cache" > /etc/zap/cache_dir
    echo "5 cdrom" >> /etc/zap/repo.list
    echo "NAME=cdrom" > /etc/zap/repositories/cdrom.repo
    echo "DESC=Tribblix packages from CD image" >> /etc/zap/repositories/cdrom.repo
    echo "URL=${PKGMEDIA}" >> /etc/zap/repositories/cdrom.repo
    /usr/lib/zap/refresh-catalog cdrom
    for overlay in base-extras $OVERLAYS
    do
	echo "Installing $overlay overlay" | tee -a $LOGFILE
	/usr/lib/zap/install-overlay -R ${ALTROOT} $overlay | tee -a $LOGFILE
    done
fi
echo "Overlay installation complete" | tee -a $LOGFILE
/usr/bin/date | tee -a $LOGFILE

echo "Deleting live package"
/usr/sbin/pkgrm -n -a /usr/lib/zap/pkg.force -R ${ALTROOT} TRIBsys-install-media-internal

#
# use a prebuilt repository if available
#
/usr/bin/rm ${ALTROOT}/etc/svc/repository.db
if [ -f ${SMFREPODIR}/repository-installed.db ]; then
    /usr/bin/cp -p ${SMFREPODIR}/repository-installed.db ${ALTROOT}/etc/svc/repository.db
elif [ -f ${SMFREPODIR}/repository-installed.db.gz ]; then
    /usr/bin/cp -p ${SMFREPODIR}/repository-installed.db.gz ${ALTROOT}/etc/svc/repository.db.gz
    /usr/bin/gunzip ${ALTROOT}/etc/svc/repository.db.gz
else
    /usr/bin/cp -p /lib/svc/seed/global.db ${ALTROOT}/etc/svc/repository.db
fi
if [ -f ${ALTROOT}/var/sadm/overlays/installed/kitchen-sink ]; then
    if [ -f ${SMFREPODIR}/repository-kitchen-sink.db.gz ]; then
	/usr/bin/rm ${ALTROOT}/etc/svc/repository.db
	/usr/bin/cp -p ${SMFREPODIR}/repository-kitchen-sink.db.gz ${ALTROOT}/etc/svc/repository.db.gz
	/usr/bin/gunzip ${ALTROOT}/etc/svc/repository.db.gz
    fi
fi

#
# reset the SMF profile from the live image to regular
#
/usr/bin/rm ${ALTROOT}/etc/svc/profile/generic.xml
/usr/bin/ln -s generic_limited_net.xml ${ALTROOT}/etc/svc/profile/generic.xml

#
# shut down pkgserv, as it blocks the unmount of the target filesystem
#
pkgadm sync -R ${ALTROOT} -q

#
echo "Installing GRUB"
for DRIVE in $DRIVELIST
do
    /sbin/installgrub -fm /boot/grub/stage1 /boot/grub/stage2 /dev/rdsk/$DRIVE
done

echo "Configuring devices"
${ALTROOT}/usr/sbin/devfsadm -r ${ALTROOT}
touch ${ALTROOT}/reconfigure

echo "Setting up boot"
/usr/bin/mkdir -p /${ROOTPOOL}/boot/grub/bootsign /${ROOTPOOL}/etc
touch /${ROOTPOOL}/boot/grub/bootsign/pool_${ROOTPOOL}
echo "pool_${ROOTPOOL}" > /${ROOTPOOL}/etc/bootsign

#
# copy any console settings to the running system
#
BCONSOLE=""
ICONSOLE=`/sbin/devprop console`
if [ ! -z "$ICONSOLE" ]; then
  BCONSOLE=",console=${ICONSOLE},input-device=${ICONSOLE},output-device=${ICONSOLE}"
fi

/usr/bin/cat > /${ROOTPOOL}/boot/grub/menu.lst << _EOF
default 0
timeout 10
title Tribblix 0.10
findroot (pool_${ROOTPOOL},0,a)
bootfs ${ROOTPOOL}/ROOT/tribblix
kernel\$ /platform/i86pc/kernel/\$ISADIR/unix -B \$ZFS-BOOTFS${BCONSOLE}
module\$ /platform/i86pc/\$ISADIR/boot_archive
_EOF

#
# set nodename if requested
#
if [ -n "$NODENAME" ]; then
    echo $NODENAME > ${ALTROOT}/etc/nodename
fi

#
# set timezone if requested
#
if [ -n "$TIMEZONE" ]; then
    mv ${ALTROOT}/etc/default/init ${ALTROOT}/etc/default/init.pre
    cat ${ALTROOT}/etc/default/init.pre | /usr/bin/sed s:PST8PDT:${TIMEZONE}: > ${ALTROOT}/etc/default/init
    rm ${ALTROOT}/etc/default/init.pre
fi

#
# FIXME: why is this so much larger than a regular system?
# FIXME and why does it take so long - it's half the install budget
#
echo "Updating boot archive"
/usr/bin/mkdir -p ${ALTROOT}/platform/i86pc/amd64
/sbin/bootadm update-archive -R ${ALTROOT}

#
# enable swap
#
/bin/echo "/dev/zvol/dsk/${ROOTPOOL}/swap\t-\t-\tswap\t-\tno\t-" >> ${ALTROOT}/etc/vfstab

#
# Copy /jack to the installed system
#
cd /
find jack -print | cpio -pmud ${ALTROOT}
/usr/bin/rm -f ${ALTROOT}/jack/.bash_history

#
# this is to fix a 3s delay in xterm startup
#
echo "*openIm: false" > ${ALTROOT}/jack/.Xdefaults
/usr/bin/chown jack:staff ${ALTROOT}/jack/.Xdefaults

#
# remove the autoinstall startup script
#
/bin/rm -f ${ALTROOT}/etc/rc2.d/S99auto_install
sync
sleep 2

#
# remount zfs filesystem in the right place for next boot
#
/usr/sbin/zfs set mountpoint=/export ${ROOTPOOL}/export
/usr/sbin/zfs set mountpoint=/ ${ROOTPOOL}/ROOT/tribblix

#
# if specified, reboot
#
case $REBOOT in
yes)
	echo "Install complete, rebooting"
	/sbin/sync
	/usr/sbin/reboot -p
	;;
esac
