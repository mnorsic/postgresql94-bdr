#!/bin/bash
set -e

if [ "${1:0:1}" = '-' ]; then
	set -- postgres "$@"
fi

if [ "$1" = 'postgres' ]; then
	mkdir -p "$PGDATA"
	chmod 700 "$PGDATA"
	chown -R postgres "$PGDATA"

	mkdir -p /run/postgresql
	chmod g+s /run/postgresql
	chown -R postgres /run/postgresql

	# look specifically for PG_VERSION, as it is expected in the DB dir
	if [ ! -s "$PGDATA/PG_VERSION" ]; then
		eval "gosu postgres initdb $POSTGRES_INITDB_ARGS"

		# check password first so we can output the warning before postgres
		# messes it up
		if [ "$POSTGRES_PASSWORD" ]; then
			pass="PASSWORD '$POSTGRES_PASSWORD'"
			authMethod=md5
		else
			# The - option suppresses leading tabs but *not* spaces. :)
			cat >&2 <<-'EOWARN'
				****************************************************
				WARNING: No password has been set for the database.
				         This will allow anyone with access to the
				         Postgres port to access your database. In
				         Docker's default configuration, this is
				         effectively any other container on the same
				         system.

				         Use "-e POSTGRES_PASSWORD=password" to set
				         it in "docker run".
				****************************************************
			EOWARN

			pass=
			authMethod=trust
		fi

		{
			echo;
			echo "host all all 0.0.0.0/0 $authMethod";
			echo "local replication postgres $authMethod";
    	echo "host replication postgres 0.0.0.0/0 $authMethod";
			echo "host replication postgres ::1/128 $authMethod";
		} | gosu postgres tee -a "$PGDATA/pg_hba.conf" > /dev/null

		{
			echo;
			echo "port = $NODE_PORT";
			echo "shared_preload_libraries = 'bdr'";
			echo "wal_level = 'logical'";
			echo "track_commit_timestamp = on";
			echo "max_connections = 100";
			echo "max_wal_senders = 10";
			echo "max_replication_slots = 10";
			echo "max_worker_processes = 10";
			echo "default_sequenceam = 'bdr'"
		} | gosu postgres tee -a "$PGDATA/postgresql.conf" > /dev/null

		# internal start of server in order to allow set-up using psql-client
		# does not listen on external TCP/IP and waits until start finishes
		gosu postgres pg_ctl -D "$PGDATA" \
			-o "-c listen_addresses='$NODE_NAME' -p $NODE_PORT" \
			-w start

		: ${POSTGRES_USER:=postgres}
		: ${POSTGRES_DB:=$POSTGRES_USER}
		export POSTGRES_USER POSTGRES_DB

		psql=( psql -p $NODE_PORT -v ON_ERROR_STOP=1 )

		if [ "$POSTGRES_DB" != 'postgres' ]; then
			"${psql[@]}" --username postgres <<-EOSQL
				CREATE DATABASE "$POSTGRES_DB" ;
			EOSQL
			echo
		fi

		if [ "$POSTGRES_USER" = 'postgres' ]; then
			op='ALTER'
		else
			op='CREATE'
		fi
		"${psql[@]}" --username postgres <<-EOSQL
			$op USER "$POSTGRES_USER" WITH SUPERUSER $pass ;
		EOSQL
		echo

		# creating BDR-specific stuff
		if [ "$PRIMARY_NODE" = true ]; then
			echo 'Creating BDR primary node...'
			"${psql[@]}" --username postgres <<-EOSQL
				CREATE EXTENSION IF NOT EXISTS btree_gist;
				CREATE EXTENSION IF NOT EXISTS bdr;
				SELECT bdr.bdr_group_create(local_node_name := '$NODE_NAME',node_external_dsn := 'port=$NODE_PORT dbname=$POSTGRES_DB host=$NODE_NAME');
				SELECT bdr.bdr_node_join_wait_for_ready();
			EOSQL
			echo 'Primary node created.'
		else
			echo 'Sleeping for 10 seconds...'
			gosu postgres sleep 10
			echo 'Creating BDR secondary node - waiting for primary node to be ready...'
			gosu postgres dockerize -wait tcp://$PRIMARY_NODE_NAME:$PRIMARY_NODE_PORT -timeout 60s
			"${psql[@]}" --username postgres <<-EOSQL
				CREATE EXTENSION IF NOT EXISTS btree_gist;
				CREATE EXTENSION IF NOT EXISTS bdr;
				SELECT bdr.bdr_group_join(local_node_name := '$NODE_NAME',node_external_dsn := 'port=$NODE_PORT dbname=$POSTGRES_DB host=$NODE_NAME',join_using_dsn := 'port=$PRIMARY_NODE_PORT dbname=$POSTGRES_DB host=$PRIMARY_NODE_NAME');
				SELECT bdr.bdr_node_join_wait_for_ready();
			EOSQL
			echo 'Secondary node created.'
		fi

		psql+=( --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" )

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)     echo "$0: running $f"; . "$f" ;;
				*.sql)    echo "$0: running $f"; "${psql[@]}" < "$f"; echo ;;
				*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${psql[@]}"; echo ;;
				*)        echo "$0: ignoring $f" ;;
			esac
			echo
		done

		gosu postgres pg_ctl -D "$PGDATA" -m fast -w stop

		echo
		echo 'PostgreSQL init process complete; ready for start up.'
		echo
	fi

	exec gosu postgres "$@"
fi

exec "$@"
