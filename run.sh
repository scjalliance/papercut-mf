#!/bin/bash

export PASSWORD

MY_HOSTNAME=$(hostname)
SERVER_TYPE="primary"
SERVER_TYPE_FLAG=""
PRIMARY_HOSTNAME="localhost"
WORKGROUP="WORKGROUP"
WANT_PRINT_SERVICE=""
KRB_REALM=""

# ENV variables:
#   KRB_USERNAME
#   KRB_PASSWORD

if [ -f /vars ]; then
	source /vars
fi

for V in "$@"; do
	case "$V" in
		--hostname=*)
			MY_HOSTNAME="${V#--hostname=}"
			;;
		--primary)
			SERVER_TYPE="primary"
			SERVER_TYPE_FLAG=""
			;;
		--site-server|site-server)
			SERVER_TYPE="site"
			SERVER_TYPE_FLAG="--site-server"
			;;
		--secondary)
			SERVER_TYPE="secondary"
			SERVER_TYPE_FLAG=""
			WANT_PRINT_SERVICE=1
			;;
		--primaryhost=*)
			PRIMARY_HOSTNAME="${V#--primaryhost=}"
			;;
		--workgroup=*)
			WORKGROUP="${V#--workgroup=}"
			;;
		--printservice)
			WANT_PRINT_SERVICE=1
			;;
		--noprintservice)
			WANT_PRINT_SERVICE=""
			;;
		--krbrealm=*)
			KRB_REALM="${V#--krbrealm=}"
			;;
	esac
done

if [ ! -z "$DEBUG" ]; then
	echo "MY_HOSTNAME=$MY_HOSTNAME"
	echo "SERVER_TYPE=$SERVER_TYPE"
	echo "SERVER_TYPE_FLAG=$SERVER_TYPE_FLAG"
	echo "PRIMARY_HOSTNAME=$PRIMARY_HOSTNAME"
	echo "WORKGROUP=$WORKGROUP"
	echo "WANT_PRINT_SERVICE=$WANT_PRINT_SERVICE"
	echo "KRB_REALM=$KRB_REALM"
fi

if [ "$SERVER_TYPE" == "secondary" -a -z "$PRIMARY_HOSTNAME" ]; then
	echo "Requires --primaryhost=<PRIMARY_HOSTNAME> value when using --secondary."
	exit 1
fi

RANDOMPASSWORD=""

# fix/hijack permissions on /papercut/server/data
chown -R papercut:papercut /papercut/server/data

# are we installed already?
if [ -x /etc/init.d/papercut-event-monitor ]; then
	if [ ! -z "$KRB_REALM" ]; then
		/etc/init.d/sssd start || exit 1
		#/etc/init.d/winbind start || exit 1
	fi

	if [ "$SERVER_TYPE" == "primary" ]; then
		if [ -f /papercut/import.zip -a ! -f /papercut/import.log ]; then
			runuser -l papercut -c "yes | /papercut/server/bin/linux-x64/db-tools import-db -f /papercut/import.zip" | tee -a /papercut/import.log
		fi
	fi

	if [ "$SERVER_TYPE" == "primary" -o "$SERVER_TYPE" == "site-server" ]; then
		/etc/init.d/papercut start || exit 1
		/etc/init.d/papercut-web-print start
	fi

	if [ ! -z "$WANT_PRINT_SERVICE" ]; then
		/etc/init.d/cups start || exit 1
	fi

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

	cd /papercut || exit 1

	if [ "$SERVER_TYPE" == "secondary" ]; then
		cp -a /installer/papercut/providers providers || exit 1
		chmod +x providers/print/linux-x64/setperms || exit 1
		providers/print/linux-x64/setperms || exit 1
		providers/print/linux-x64/roottasks || exit 1
	else
		runuser -l papercut -c "cd /installer/papercut && bash install $SERVER_TYPE_FLAG" || exit 1
		sed -i "s/admin.password=password/admin.password=$PASSWORD/" server/server.properties || exit 1
		bash MUST-RUN-AS-ROOT || exit 1
        	/etc/init.d/papercut stop
	        /etc/init.d/papercut-web-print stop
        	/etc/init.d/papercut-event-monitor stop

		if [ ! -z "$RANDOMPASSWORD" -a ! -z "$PASSWORD" ]; then
			echo "PASSWORD HAS BEEN SET TO $PASSWORD FOR USER admin"
		fi
	fi

	if [ ! -z "$WANT_PRINT_SERVICE" ]; then
		# CUPS config: http://www.papercut.com/products/ng/manual/ch-linux.html#linux-install-print-queue-integration
		#providers/print/linux-x64/configure-cups || exit 1

		# set my hostname for PaperCut reporting
		sed -i "s/#* *ServerName *=.*/ServerName=$MY_HOSTNAME/" providers/print/linux-x64/print-provider.conf || exit 1

		if [ "$SERVER_TYPE" == "secondary" ]; then
			# set my upstream
			sed -i "s/#* *ApplicationServer *=.*/ApplicationServer=$PRIMARY_HOSTNAME/" providers/print/linux-x64/print-provider.conf || exit 1
		fi

		# get CUPS to listen on all IPs
		sed -i "s/#* *Listen localhost:631/Listen 0.0.0.0:631/" /etc/cups/cupsd.conf || exit 1

		# allow access to CUPS web UI
		awk -i inplace "/WebInterface/ { print; print \"DefaultEncryption Never\"; next }1" /etc/cups/cupsd.conf || exit 1
		awk -i inplace "/<Location \// { print; print \"Allow from all\"; next }1" /etc/cups/cupsd.conf || exit 1

		# create the printadmin user for CUPS
		useradd -mU -G lpadmin -p $(openssl passwd -1 -salt "$(hostname)" "$PASSWORD") printadmin

		# set Samba print command to use PaperCut
		sed -i 's/.*print command *=.*//' /etc/samba/smb.conf
		awk -i inplace '/\[global\]/ { print; print "print command = /papercut/providers/print/linux-x64/samba-print-provider -u \"%u\" -J \"%J\" -h \"%h\" -m \"%m\" -p \"%p\" -s \"%s\" -a \"lp -c -d%p %s; rm %s\" &@"; next }1' /etc/samba/smb.conf

		# set Samba to use CUPS
		sed -i 's/.*printing *=.*//' /etc/samba/smb.conf
		awk -i inplace '/\[global\]/ { print; print "printing = cups"; next }1' /etc/samba/smb.conf
		sed -i 's/.*printcap *name *=.*//' /etc/samba/smb.conf
		awk -i inplace '/\[global\]/ { print; print "printcap name = cups"; next }1' /etc/samba/smb.conf
		sed -i 's/.*load *printers *=.*//' /etc/samba/smb.conf
		awk -i inplace '/\[global\]/ { print; print "load printers = yes"; next }1' /etc/samba/smb.conf

		# set Samba printer admin groups
		sed -i 's/.*write *list *=.*//' /etc/samba/smb.conf
		awk -i inplace '/\[print\$\]/ { print; print "   write list = @lpadmin"; next }1' /etc/samba/smb.conf
		#sed -i 's/.*printer *admin *=.*//' /etc/samba/smb.conf
		#awk -i inplace '/\[printers\]/ { print; print "printer admin = @lpadmin"; next }1' /etc/samba/smb.conf

		# set Samba permissions
		sed -i 's/.*read *only *=.*//' /etc/samba/smb.conf
		awk -i inplace '/\[print\$\]/ { print; print "   read only = yes"; next }1' /etc/samba/smb.conf
	fi

	# set Samba hostname
	sed -i "s/;*#* *netbios name *=.*//" /etc/samba/smb.conf
	awk -i inplace "/\[global\]/ { print; print \"netbios name = $MY_HOSTNAME\"; next }1" /etc/samba/smb.conf
	sed -i "s/;*#* *workgroup *=.*//" /etc/samba/smb.conf
	awk -i inplace "/\[global\]/ { print; print \"workgroup = $WORKGROUP\"; next }1" /etc/samba/smb.conf

	# set Samba AD membership
	if [ ! -z "$KRB_REALM" ]; then
		sed -i "s/;*#* *security *=.*//" /etc/samba/smb.conf
		awk -i inplace "/\[global\]/ { print; print \"security = ADS\"; next }1" /etc/samba/smb.conf
		sed -i "s/;*#* *realm *=.*//" /etc/samba/smb.conf
		awk -i inplace "/\[global\]/ { print; print \"realm = $KRB_REALM\"; next }1" /etc/samba/smb.conf
		sed -i "s/;*#* *kerberos *method *=.*//" /etc/samba/smb.conf
		awk -i inplace "/\[global\]/ { print; print \"kerberos method = secrets and keytab\"; next }1" /etc/samba/smb.conf
	fi

	# are we attaching to Active Directory?
	# FIXME: maybe we should be sure it works for Kerberos? (not just Microsoft-style AD)
	if [ ! -z "$KRB_REALM" ]; then
		sed -i "s/#* *default_realm *=.*/default_realm = $KRB_REALM/" /etc/krb5.conf

		if [ ! -z "$KRB_USERNAME" -a ! -z "$KRB_PASSWORD" ]; then
			# join the domain
			echo "${KRB_PASSWORD}" | net ads join -U ${KRB_USERNAME}@${KRB_REALM}

			# setup sssd
			KRB5_KTNAME=FILE:/etc/krb5.sssd.keytab net ads keytab create -P
			echo -e "[sssd]\nservices=nss,pam\nconfig_file_version=2\ndomains=${KRB_REALM}\n\n" > /etc/sssd/sssd.conf
			echo -e "[nss]\n\n" >> /etc/sssd/sssd.conf
			echo -e "[pam]\n\n" >> /etc/sssd/sssd.conf
			echo -e "[domain/${KRB_REALM}]\nenumerate=true\nid_provider=ad\naccess_provider=ad\nkrb5_keytab=/etc/krb5.sssd.keytab\n\n" >> /etc/sssd/sssd.conf
			chmod 600 /etc/sssd/sssd.conf
		fi
	fi

	# remove unusable backends
	rm -f /usr/lib/cups/backend/{parallel,serial,usb}

	"$0" $*
	exit

# no installer?  bad news, friend.
else
	echo "ERROR: The installer is missing, somehow.  Can't continue."
	exit 1
fi
