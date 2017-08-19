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

usage() { echo "Usage: $0 -u REPLICA_USER -p REPLICA_PASS -U ROOT_USER -P ROOT_PASS -d DB -m MASTER_HOST -s SLAVE_HOSTS_WITH_COLON" 1>&2; exit 1; }

# default values
DB=djangodb

ROOT_USER=root
ROOT_PASS=root

REPLICA_USER=$ROOT_USER
REPLICA_PASS=$ROOT_PASS

MASTER_HOST=192.168.0.201
SLAVE_HOSTS=(192.168.0.202 192.168.0.203)

# override through options
while getopts ":d:u:p:U:P:m:s:S:" o; do
	case "${o}" in
		d)
			DB=${OPTARG}
			;;
		u)
			REPLICA_USER=${OPTARG}
			;;
		p)
			REPLICA_PASS=${OPTARG}
			;;
		U)
			ROOT_USER=${OPTARG}
			;;
		P)
			ROOT_PASS=${OPTARG}
			;;
		m)
			MASTER_HOST=${OPTARG}
			;;
		s)
			unset SLAVE_HOSTS
			IFS=':' read -a SLAVE_HOSTS <<< ${OPTARG}
			;;
		S)
			SCP_PORT_ARG="-P ${OPTARG}"
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

mysql -h $MASTER_HOST -u $ROOT_USER --password=$ROOT_PASS $DB <<-EOSQL &
	GRANT REPLICATION SLAVE ON *.* TO '$REPLICA_USER'@'%' IDENTIFIED BY '$REPLICA_PASS';
	FLUSH PRIVILEGES;
	FLUSH TABLES WITH READ LOCK;
	DO SLEEP(3600);
EOSQL

echo "  - Waiting for database to be locked"
sleep 3

# Dump the database (to the client executing this script) while it is locked
echo "  - Dumping database to $DUMP_FILE"
mysqldump -h $MASTER_HOST "-u$ROOT_USER" "-p$ROOT_PASS" --opt $DB > $DUMP_FILE
echo "  - Dump complete."

# Take note of the master log position at the time of dump
MASTER_STATUS=$(mysql -h $MASTER_HOST "-u$ROOT_USER" "-p$ROOT_PASS" -ANe "SHOW MASTER STATUS;" | awk '{print $1 " " $2}')
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
	mysql -h $SLAVE_HOST "-u$ROOT_USER" "-p$ROOT_PASS" -e "DROP DATABASE IF EXISTS $DB; CREATE DATABASE $DB;"
	scp $SCP_PORT_ARG $DUMP_FILE $SLAVE_HOST:$DUMP_FILE >/dev/null
	mysql -h $SLAVE_HOST "-u$ROOT_USER" "-p$ROOT_PASS" $DB < $DUMP_FILE

	echo "  - Setting up slave replication"
	mysql -h $SLAVE_HOST "-u$ROOT_USER" "-p$ROOT_PASS" $DB <<-EOSQL &
		STOP SLAVE;
		CHANGE MASTER TO MASTER_HOST='$MASTER_HOST',
		MASTER_USER='$REPLICA_USER',
		MASTER_PASSWORD='$REPLICA_PASS',
		MASTER_LOG_FILE='$LOG_FILE',
		MASTER_LOG_POS=$LOG_POS;
		START SLAVE;
	EOSQL
	# Wait for slave to get started and have the correct status
	sleep 2
	# Check if replication status is OK
	SLAVE_OK=$(mysql -h $SLAVE_HOST "-u$ROOT_USER" "-p$ROOT_PASS" -e "SHOW SLAVE STATUS\G;" | grep 'Waiting for master')
	if [ -z "$SLAVE_OK" ]; then
		echo "  - Error ! Wrong slave IO state."
	else
		echo "  - Slave IO state OK"
	fi
done
