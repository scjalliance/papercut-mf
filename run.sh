#!/bin/bash

SERVERTYPE=""

case "$1" in
	site-server)
		SERVERTYPE="--site-server"
		;;
esac

RANDOMPASSWORD=""

# fix/hijack permissions on /papercut/server/data
chown -R papercut:papercut /papercut/server/data

# are we installed already?
if [ -x /etc/init.d/papercut ]; then
	if [ -f /papercut/import.zip -a ! -f /papercut/import.log ]; then
		runuser -l papercut -c "yes | /papercut/server/bin/linux-x64/db-tools import-db -f /papercut/import.zip" | tee -a /papercut/import.log
	fi

        /etc/init.d/papercut start || exit 1
        /etc/init.d/papercut-web-print start
        /etc/init.d/papercut-event-monitor start
	sleep 99999d # or something...
	exit

# do we have the installer payload?
elif [ -f /installer/pcmf-setup.sh ]; then
	echo INSTALLING...

	if [ -z "$PASSWORD" ]; then
		PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
		echo "PASSWORD WILL BE SET TO $PASSWORD FOR USER admin"
		RANDOMPASSWORD=1
	fi

	cd /installer || exit 1
	bash pcmf-setup.sh -e || exit 1
	cd papercut || exit 1
	mv LICENCE.TXT PAPERCUT-MF-LICENCE.TXT || exit 1
	sed -i 's/answered=/answered=1/' install || exit 1
	sed -i 's/manual=/manual=1/' install || exit 1
	sed -i 's/read reply/#read reply/g' install || exit 1
	runuser -l papercut -c "cd /installer/papercut && bash install $SERVERTYPE" || exit 1
	cd /papercut || exit 1
	sed -i "s/admin.password=password/admin.password=$PASSWORD/" server/server.properties || exit 1
	bash MUST-RUN-AS-ROOT || exit 1
        /etc/init.d/papercut stop
        /etc/init.d/papercut-web-print stop
        /etc/init.d/papercut-event-monitor stop

	if [ ! -z "$RANDOMPASSWORD" -a ! -z "$PASSWORD" ]; then
		echo "PASSWORD HAS BEEN SET TO $PASSWORD FOR USER admin"
	fi

	"$0" $*
	exit

# no installer?  bad news, friend.
else
	echo "ERROR: The installer is missing, somehow.  Can't continue."
	exit 1
fi
