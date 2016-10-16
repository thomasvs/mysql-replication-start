#!/bin/bash
#title			: mysql-replication-start.sh
#description		: This script automates the process of starting a Mysql Replication on 1 master node and N slave nodes.
#author		 	: Nicolas Di Tullio
#date			: 20160706
#version		: 0.2
#usage			: bash mysql-replication-start.sh
#bash_version		: 4.3.11(1)-release
#=============================================================================

#
# Requirements for this script to work:
# * The Mysql user defined by the $USER variable must:
#   - Have the same password $PASS on all mysql instances
#   - Be able to grant replication privileges
#   - All hosts must be able to receive mysql commands remotely from the node executing this script
#

usage() { echo "Usage: $0" 1>&2; exit 1; }

# default values
DB=djangodb

USER=root
PASS=root

MASTER_HOST=192.168.0.201
SLAVE_HOSTS=(192.168.0.202 192.168.0.203)

# override through options
while getopts ":d:u:p:m:s:" o; do
	case "${o}" in
		d)
			DB=${OPTARG}
			;;
		u)
			USER=${OPTARG}
			;;
		p)
			PASS=${OPTARG}
			;;
		m)
			MASTER_HOST=${OPTARG}
			;;
		s)
			unset SLAVE_HOSTS
			SLAVE_HOSTS=$(echo ${OPTARG} | tr ":" "\n")
			;;
		*)
			usage
			;;
	esac
done
shift $((OPTIND-1))

DUMP_FILE="/tmp/$DB-export-$(date +"%Y%m%d%H%M%S").sql"

##
# MASTER
# ------
# Export database and read log position from master, while locked
##

echo "MASTER: $MASTER_HOST"

mysql -h $MASTER_HOST "-u$USER" "-p$PASS" $DB <<-EOSQL &
	GRANT REPLICATION SLAVE ON *.* TO '$USER'@'%' IDENTIFIED BY '$PASS';
	FLUSH PRIVILEGES;
	FLUSH TABLES WITH READ LOCK;
	DO SLEEP(3600);
EOSQL

echo "  - Waiting for database to be locked"
sleep 3

# Dump the database (to the client executing this script) while it is locked
echo "  - Dumping database to $DUMP_FILE"
mysqldump -h $MASTER_HOST "-u$USER" "-p$PASS" --opt $DB > $DUMP_FILE
echo "  - Dump complete."

# Take note of the master log position at the time of dump
MASTER_STATUS=$(mysql -h $MASTER_HOST "-u$USER" "-p$PASS" -ANe "SHOW MASTER STATUS;" | awk '{print $1 " " $2}')
LOG_FILE=$(echo $MASTER_STATUS | cut -f1 -d ' ')
LOG_POS=$(echo $MASTER_STATUS | cut -f2 -d ' ')
echo "  - Current log file is $LOG_FILE and log position is $LOG_POS"

# When finished, kill the background locking command to unlock
kill $! 2>/dev/null
wait $! 2>/dev/null

echo "  - Master database unlocked"

##
# SLAVES
# ------
# Import the dump into slaves and activate replication with
# binary log file and log position obtained from master.
##

for SLAVE_HOST in "${SLAVE_HOSTS[@]}"
do
	echo "SLAVE: $SLAVE_HOST"
	echo "  - Creating database copy"
	mysql -h $SLAVE_HOST "-u$USER" "-p$PASS" -e "DROP DATABASE IF EXISTS $DB; CREATE DATABASE $DB;"
	scp $DUMP_FILE $SLAVE_HOST:$DUMP_FILE >/dev/null
	mysql -h $SLAVE_HOST "-u$USER" "-p$PASS" $DB < $DUMP_FILE

	echo "  - Setting up slave replication"
	mysql -h $SLAVE_HOST "-u$USER" "-p$PASS" $DB <<-EOSQL &
		STOP SLAVE;
		CHANGE MASTER TO MASTER_HOST='$MASTER_HOST',
		MASTER_USER='$USER',
		MASTER_PASSWORD='$USER',
		MASTER_LOG_FILE='$LOG_FILE',
		MASTER_LOG_POS=$LOG_POS;
		START SLAVE;
	EOSQL
	# Wait for slave to get started and have the correct status
	sleep 2
	# Check if replication status is OK
	SLAVE_OK=$(mysql -h $SLAVE_HOST "-u$USER" "-p$PASS" -e "SHOW SLAVE STATUS\G;" | grep 'Waiting for master')
	if [ -z "$SLAVE_OK" ]; then
		echo "  - Error ! Wrong slave IO state."
	else
		echo "  - Slave IO state OK"
	fi
done
