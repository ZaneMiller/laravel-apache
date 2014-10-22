#!/bin/bash
set -e

#File paths
TEMP_FILE='/tmp/mysql-init.sql'

#We will restart it in the forground at the end of the script
service apache2 stop

#bootstrap the mysql server, if needed
mysql_install_db --user=mysql --datadir=/var/lib/mysql

#start the MySQL server
service mysql restart


#Make sure the root password was provided
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
	echo >&2 'error: database is uninitialized and MYSQL_ROOT_PASSWORD not set'
	echo >&2 '  Did you forget to add -e MYSQL_ROOT_PASSWORD=... ?'
	exit 1
fi

#Set the root password/clear out the test db
cat > "$TEMP_FILE" <<-EOSQL
	DELETE FROM mysql.user ;
	GRANT ALL ON *.* TO 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' WITH GRANT OPTION ;
	DROP DATABASE IF EXISTS test ;
EOSQL

#Loop through the MYSQL_DATABASES array and create each DB
if [ "$MYSQL_DATABASES" ]; then
	for db in $MYSQL_DATABASES; do
		echo "CREATE DATABASE IF NOT EXISTS $db;" >> "$TEMP_FILE"
	done
fi

#Add all given permissions to users on tables
#This will create users if they do not exist already
if [ "$MYSQL_PERMISSIONS" ]; then
	for PERM in $MYSQL_PERMISSIONS; do
		while IFS=':' read -ra PERM_DATA; do
			echo "GRANT ${PERM_DATA[3]} ON ${PERM_DATA[4]}.* TO '${PERM_DATA[0]}'@'${PERM_DATA[1]}' IDENTIFIED BY '${PERM_DATA[2]}' ;" >> "$TEMP_FILE"
		done <<< $PERM
	done
fi

echo 'FLUSH PRIVILEGES ;' >> "$TEMP_FILE"

#make sure mysql can do what it needs to do
chown -R mysql:mysql /var/lib/mysql

#load the MySQL script, attempts to run it first without the set root password, if it cannot runs it again with the root password
mysql < $TEMP_FILE || mysql --password=$MYSQL_ROOT_PASSWORD < $TEMP_FILE

#Run migrations
if [ "$LARAVEL_MIGRATE" ]; then
	php /var/www/html/artisan migrate -n --seed
fi

#Launch apache in the foreground
#We do this in the forground so that Docker can watch
#the process to detect if it has crashed
apache2 -DFOREGROUND