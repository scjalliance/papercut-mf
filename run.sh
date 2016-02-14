#!/bin/bash

SERVERTYPE=""

case "$1" in
	site-server)
		SERVERTYPE="--site-server"
		;;
esac

# are we installed already?
if [ -x /etc/init.d/papercut ]; then
        /etc/init.d/papercut start
        /etc/init.d/papercut-event-monitor start
	dmesg -w # or something...
	exit

# do we have the installer payload?
elif [ -f /installer/pcmf-setup.sh ]; then
	echo INSTALLING...
	cd /installer || exit 1
	bash pcmf-setup.sh -e || exit 1
	cd papercut || exit 1
	mv LICENCE.TXT PAPERCUT-MF-LICENCE.TXT || exit 1
	sed -i 's/answered=/answered=1/' install || exit 1
	sed -i 's/manual=/manual=1/' install || exit 1
	sed -i 's/read reply/#read reply/g' install || exit 1
	runuser -l papercut -c "cd /installer/papercut && bash install $SERVERTYPE" || exit 1
	cd /papercut || exit 1
	bash MUST-RUN-AS-ROOT || exit 1
	"$0" $*
	exit

# no installer?  bad news, friend.
else
	echo "ERROR: The installer is missing, somehow.  Can't continue."
	exit 1
fi
