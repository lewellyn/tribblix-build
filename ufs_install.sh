#!/bin/sh
#
# FIXME: do fdisk and partitions first
#
# This installs to ufs. Must be a partition on a single physical disk.
#
# The assumption is that root=s0 swap=s1
# and that the drive is already partitioned
#

case $# in
0)
	echo "Usage: $0 device [overlay ... ]"
	exit 1
	;;
esac

#
# these properties are available for customization
#
SWAPSIZE="2g"
ZFSARGS=""
BFLAG=""
REBOOT="no"
OVERLAYS=""
NODENAME=""
TIMEZONE=""
DOMAINNAME=""
BEGIN_SCRIPT=""
FINISH_SCRIPT=""
FIRSTBOOT_SCRIPT=""

FSTYPE="UFS"
DRIVE1=""
PKGLOC="/.cdrom/pkgs"
SMFREPODIR="/usr/lib/zap"
ALTROOT="/a"

WCLIENT=/usr/bin/curl
WARGS="-f -s -S --retry 6 -o"
if [ ! -x $WCLIENT ]; then
    WCLIENT=/usr/bin/wget
    WARGS="-q --tries=6 --retry-connrefused --waitretry=2 -O"
fi

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
	    ${WCLIENT} ${WARGS} $TMPF $IPROFILE
	done
	. $TMPF
	rm -fr $TMPF
	;;
esac
fi

#
# begin script handling
# the begin script is run and its output saved
# then we source the output, this allows you to
# dynamically create install settings
#
if [ -n "$BEGIN_SCRIPT" ]; then
BEGINF="/tmp/begin.$$"
case $BEGIN_SCRIPT in
nfs*)
	TMPMNT="/tmp/mnt1"
	mkdir -p ${TMPMNT}
	IPROFDIR=${BEGIN_SCRIPT%/*}
	IPROFNAME=${BEGIN_SCRIPT##*/}
	mount $IPROFDIR $TMPMNT
	if [ -f ${TMPMNT}/${IPROFNAME} ]; then
	    ${TMPMNT}/${IPROFNAME} > $BEGINF
	fi
	umount ${TMPMNT}
	rmdir ${TMPMNT}
	;;
http*)
	TMPF="/tmp/profile.$$"
	${WCLIENT} ${WARGS} $TMPF $BEGIN_SCRIPT
	if [ -s "$TMPF" ]; then
	    chmod a+x $TMPF
	    $TMPF > $BEGINF
	fi
	rm -f $TMPF
	;;
esac
if [ -s "$BEGINF" ]; then
    . $BEGINF
fi
rm -f $BEGINF
fi

#
# interactive argument handling
#
while getopts "n:t:" opt; do
    case $opt in
        n)
	    NODENAME="$OPTARG"
	    ;;
        t)
	    TIMEZONE="$OPTARG"
	    ;;
    esac
done
shift $((OPTIND-1))

case $# in
0)
	echo "Usage: $0 device [overlay ... ]"
	exit 1
	;;
esac

DRIVE1=$1
shift

if [ ! -e /dev/dsk/$DRIVE1 ]; then
    echo "ERROR: Unable to find device $DRIVE1"
    exit 1
fi

case $DRIVE1 in
*s0)
	SWAPDEV=`echo $DRIVE1 | sed 's:s0$:s1:'`
	;;
*)
	echo "ERROR: Root slice must be slice 0"
	exit 1
	;;
esac

/usr/bin/mkdir -p ${ALTROOT}
echo "Creating root file system"
env NOINUSE_CHECK=1 /usr/sbin/newfs /dev/rdsk/$DRIVE1
/usr/sbin/mount /dev/dsk/$DRIVE1 ${ALTROOT}
mkdir -p ${ALTROOT}/export/home

echo "Copying main filesystems"
cd /
ZONELIB=""
if [ -d zonelib ]; then
    ZONELIB="zonelib"
fi
/usr/bin/find boot kernel lib platform root sbin usr etc var opt ${ZONELIB} -print -depth | cpio -pdm ${ALTROOT}

#
echo "Adding extra directories"
cd ${ALTROOT}
/usr/bin/ln -s ./usr/bin .
/usr/bin/mkdir -m 1777 tmp
/usr/bin/mkdir -p system/contract system/object system/boot proc mnt dev devices/pseudo
/usr/bin/mkdir -p dev/fd dev/rmt dev/swap dev/dsk dev/rdsk dev/net dev/ipnet
/usr/bin/mkdir -p dev/sad dev/pts dev/term dev/vt dev/zcons
/usr/bin/chgrp -R sys dev devices mnt
/usr/bin/chmod 555 system system/* proc
cd dev
/usr/bin/ln -s ./fd/2 stderr
/usr/bin/ln -s ./fd/1 stdout
/usr/bin/ln -s ./fd/0 stdin
/usr/bin/ln -s ../devices/pseudo/dld@0:ctl dld
cd /

#
# delete mkisofs from the installed image, we have an unpackaged copy
# on the bootable /usr which we use to optimize boot archive creation
#
/usr/bin/rm -f ${ALTROOT}/usr/bin/mkisofs

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
swap -a /dev/dsk/$SWAPDEV
LOGFILE="${ALTROOT}/var/sadm/install/logs/initial.log"
echo "Installing overlays" | tee $LOGFILE
/usr/bin/date | tee -a $LOGFILE
TMPDIR=/tmp
export TMPDIR
PKGMEDIA=`/sbin/devprop install_pkgs`
if [ -d ${PKGLOC} ]; then
    for overlay in base $*
    do
	echo "Installing $overlay overlay" | tee -a $LOGFILE
	/usr/lib/zap/install-overlay -R ${ALTROOT} -s ${PKGLOC} $overlay | tee -a $LOGFILE
    done
elif [ -z "$PKGMEDIA" ]; then
    echo "No local packages found, trying to install overlays from the network"
    echo "${ALTROOT}/var/zap/cache" > /etc/zap/cache_dir
    /usr/lib/zap/install-overlay -R ${ALTROOT} base | tee -a $LOGFILE
    # only try other overlays if base worked, to minimize wasteage
    if [ -f ${ALTROOT}/var/sadm/overlays/installed/base ]; then
	for overlay in $OVERLAYS
	do
	    /usr/lib/zap/install-overlay -R ${ALTROOT} $overlay | tee -a $LOGFILE
	done
    else
	echo "Ignoring overlay installation"
    fi
else
    echo "${ALTROOT}/var/zap/cache" > /etc/zap/cache_dir
    echo "5 cdrom" >> /etc/zap/repo.list
    echo "NAME=cdrom" > /etc/zap/repositories/cdrom.repo
    echo "DESC=Tribblix packages from CD image" >> /etc/zap/repositories/cdrom.repo
    echo "URL=${PKGMEDIA}" >> /etc/zap/repositories/cdrom.repo
    /usr/lib/zap/refresh-catalog cdrom
    for overlay in base $*
    do
	echo "Installing $overlay overlay" | tee -a $LOGFILE
	/usr/lib/zap/install-overlay -R ${ALTROOT} $overlay | tee -a $LOGFILE
    done
fi
echo "Overlay installation complete" | tee -a $LOGFILE
/usr/bin/date | tee -a $LOGFILE

echo "Deleting live package"
/usr/bin/zap uninstall -R ${ALTROOT} TRIBsys-install-media-internal

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
#
# We have an x11 version because we have to enable hal
#
if [ -f ${ALTROOT}/var/sadm/overlays/installed/x11 ]; then
    if [ -f ${SMFREPODIR}/repository-x11.db.gz ]; then
	/usr/bin/rm ${ALTROOT}/etc/svc/repository.db
	/usr/bin/cp -p ${SMFREPODIR}/repository-x11.db.gz ${ALTROOT}/etc/svc/repository.db.gz
	/usr/bin/gunzip ${ALTROOT}/etc/svc/repository.db.gz
    fi
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
echo "Installing boot loader"
if [ -f ${ALTROOT}/boot/cdboot ]; then
    /usr/sbin/installboot -f -m /boot/pmbr /boot/gptzfsboot /dev/rdsk/$DRIVE1
else
    /sbin/installgrub -fm /boot/grub/stage1 /boot/grub/stage2 /dev/rdsk/$DRIVE1
fi

echo "Configuring devices"
${ALTROOT}/usr/sbin/devfsadm -r ${ALTROOT}
touch ${ALTROOT}/reconfigure

echo "Setting up boot"
/usr/bin/mkdir -p ${ALTROOT}/boot/grub/bootsign ${ALTROOT}/etc
touch ${ALTROOT}/boot/grub/bootsign/tribblix_20.4
echo "tribblix_20.4" > ${ALTROOT}/etc/bootsign

#
# copy any console settings to the running system
#
BCONSOLE=""
ICONSOLE=`/sbin/devprop console`
if [ ! -z "$ICONSOLE" ]; then
  BCONSOLE=" -B console=${ICONSOLE},input-device=${ICONSOLE},output-device=${ICONSOLE}"
fi

/usr/bin/cat > ${ALTROOT}/boot/grub/menu.lst << _EOF
default 0
timeout 3
title Tribblix 0.20.4
findroot (tribblix_20.4,0,a)
kernel\$ /platform/i86pc/kernel/\$ISADIR/unix${BCONSOLE}
module\$ /platform/i86pc/\$ISADIR/boot_archive
_EOF

#
# mount / at boot and enable swap
#
/bin/echo "/dev/dsk/$DRIVE1\t/dev/rdsk/$DRIVE1\t/\tufs\t1\tno\tlogging" >> ${ALTROOT}/etc/vfstab
/bin/echo "/dev/dsk/$SWAPDEV\t-\t-\tswap\t-\tno\t-" >> ${ALTROOT}/etc/vfstab

#
# need to put the device path of the root slice into bootenv.rc so
# the boot can find it
#
BOOTDEV=`/bin/ls -l /dev/dsk/$DRIVE1 | awk '{print $NF}' | sed s:../../devices::'`
echo "setprop bootpath '$BOOTDEV'" >> ${ALTROOT}/boot/solaris/bootenv.rc

#
# set nodename if requested
#
if [ -n "$NODENAME" ]; then
    echo $NODENAME > ${ALTROOT}/etc/nodename
fi

#
# set domain name if requested
#
if [ -n "$DOMAINNAME" ]; then
    echo $DOMAINNAME > ${ALTROOT}/etc/defaultdomain
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
# if specified, run a finish script
# the new root directory is passed as the only argument
#
if [ -n "$FINISH_SCRIPT" ]; then
case $FINISH_SCRIPT in
nfs*)
	TMPMNT="/tmp/mnt1"
	mkdir -p ${TMPMNT}
	IPROFDIR=${FINISH_SCRIPT%/*}
	IPROFNAME=${FINISH_SCRIPT##*/}
	mount $IPROFDIR $TMPMNT
	if [ -f ${TMPMNT}/${IPROFNAME} ]; then
	    ${TMPMNT}/${IPROFNAME} ${ALTROOT}
	fi
	umount ${TMPMNT}
	rmdir ${TMPMNT}
	;;
http*)
	TMPF="/tmp/profile.$$"
	${WCLIENT} ${WARGS} $TMPF $FINISH_SCRIPT
	if [ -s "$TMPF" ]; then
	    chmod a+x $TMPF
	    $TMPF ${ALTROOT}
	fi
	rm -f $TMPF
	;;
esac
fi

#
# remove the autoinstall startup script
#
/bin/rm -f ${ALTROOT}/etc/rc2.d/S99auto_install
sync
sleep 2

#
# if specified, enable a first-boot script
#
if [ -n "$FIRSTBOOT_SCRIPT" ]; then
FIRSTDIR="${ALTROOT}/etc/tribblix"
FIRSTF="${FIRSTDIR}/firstboot"
mkdir ${FIRSTDIR}
case $FIRSTBOOT_SCRIPT in
nfs*)
	TMPMNT="/tmp/mnt1"
	mkdir -p ${TMPMNT}
	IPROFDIR=${FIRSTBOOT_SCRIPT%/*}
	IPROFNAME=${FIRSTBOOT_SCRIPT##*/}
	mount $IPROFDIR $TMPMNT
	if [ -f ${TMPMNT}/${IPROFNAME} ]; then
	    cp ${TMPMNT}/${IPROFNAME} ${FIRSTF}
	fi
	umount ${TMPMNT}
	rmdir ${TMPMNT}
	;;
http*)
	TMPF="/tmp/profile.$$"
	${WCLIENT} ${WARGS} $TMPF $FIRSTBOOT_SCRIPT
	if [ -s "$TMPF" ]; then
	    cp $TMPF $FIRSTF
	fi
	rm -f $TMPF
	;;
esac
if [ -s "${FIRSTF}" ]; then
    chmod a+x $FIRSTF
cat >> ${ALTROOT}/etc/rc3.d/S99firstboot <<EOF
#!/bin/sh
if [ -f /etc/tribblix/firstboot ]; then
mv /etc/tribblix/firstboot /etc/tribblix/firstboot.run
/etc/tribblix/firstboot.run
rm /etc/tribblix/firstboot.run
fi
rm /etc/rc3.d/S99firstboot
EOF
    chmod a+x ${ALTROOT}/etc/rc3.d/S99firstboot
fi
fi

#
# copy selected keyboard type to installed system
#
KLAYOUT=`/usr/bin/kbd -l | /usr/bin/grep layout= | /usr/bin/awk -F= '{print $2}' | /usr/bin/awk '{print $1}'`
if [ -n "${KLAYOUT}" ]; then
  NLAYOUT=`/usr/bin/nawk -v ntyp=${KLAYOUT} -F= '{if ($2 == ntyp) print $1}' /usr/share/lib/keytables/type_6/kbd_layouts`
  if [ -n "${NLAYOUT}" ]; then
    /usr/bin/grep -v keyboard-layout ${ALTROOT}/boot/solaris/bootenv.rc > ${ALTROOT}/boot/solaris/bootenv.rc.tmp
    echo "setprop keyboard-layout ${NLAYOUT}" >> ${ALTROOT}/boot/solaris/bootenv.rc.tmp
    /usr/bin/mv ${ALTROOT}/boot/solaris/bootenv.rc.tmp ${ALTROOT}/boot/solaris/bootenv.rc
    /usr/bin/rm -f /tmp/keymap-set
    echo "repository ${ALTROOT}/etc/svc/repository.db" > /tmp/keymap-set
    echo "select keymap:default" >> /tmp/keymap-set
    echo "setprop keymap/layout=${NLAYOUT}"  >> /tmp/keymap-set
    /usr/sbin/svccfg -f /tmp/keymap-set
    /usr/bin/rm -f /tmp/keymap-set
  fi
fi

#
# moved later, must be done after we change any files such as bootenv.rc
#
echo "Updating boot archive"
/usr/bin/mkdir -p ${ALTROOT}/platform/i86pc/amd64
/sbin/bootadm update-archive -R ${ALTROOT}
/sbin/sync
sleep 2

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
