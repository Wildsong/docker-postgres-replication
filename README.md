# docker-postgres-replication

Postgres 15 and pgadmin4 running in docker containers in perfect harmony.

In fact, TWO COPIES of Postgres, with data replication!

There's a Dockerfile and we build our own image because we want to use this with
Esri as an Enterprise Geodatabase Server so it needs to have st_geometry.so
installed. That's also why the "old" version of Postgres.

If you don't know what an "Enterprise Geodatabase Server" is, it is a database
server with support for storing Esri ArcGIS geometry data in its tables.

I wanted to test replication because it's used by the Esri ArcGIS DataStore product,
and it's not working in my production server right now! So I need to learn how
it works to be able to test and repair it.

## Caveat emptor

This project is not set up for production use, it's just for experimentation and testing.

## Data storage

* postgres uses docker volumes postgres_data and postgres_standby_data
* pgadmin uses a docker volume pgadmin_data

## Build

### Prerequisite

Download and unpack the st_geometry file from Esri.
In https://my.esri.com/#/downloads/product?product-ArcGIS%20Enterprise%20(Linux)&version=11.2 it's
under Database Support Files ArcGIS Pro ST_Geometry Libraries (PostgreSQL).
The file I grabbed today was ArcGIS_Enterprise_112_ST_Geometry_PostgreSQL_188228.zip.
It unzips into PostgreSQL/ and I reference the geometry file directly in Dockerfile.postgres

### Configuration

Copy sample.env to .env and then edit it to set a username and password.

### Build Docker images

    docker compose build

## Deploy

### Start

    docker compose up -d

This should start two instances of Postgres, in compose.yam hostname are set to "pp" (for "Postgres Primary") and "ps" (for "Postgres Standby")

The primary database is exposed locally on port 5432 and the standby, on port 5433.

Once it's started I usually track the logs with

    docker compose logs --follow

#### Access via browser

It also starts pgadmin. You can access pgadmin on port 8213, i.e.
http://localhost:8213/browser/ -- please note it's not encrypted and you have
to send usernames and passwords over it to use it.

You have to set up connections to "pp" and "ps" with the credentials you put in
the .env file. Once you do they will be persisted.

### Stop

    docker compose down

## Activate replication

Refer to the docs, https://www.postgresql.org/docs/15/runtime-config-replication.html

Use pgadmin to talk to the two servers and configure replication.
We rely on the fact that it's already enabled by default in 
the configuration file, /var/lib/postgres/data/postgresql.conf. 
For your perusal there is a copy of today's postgresql.conf checked in here.
It's just for reference, it's not used anywhere.

### On primary "sending" server

Working in a shell is easiest. Look up the id of the primary, open a shell.

   docker exec -it `docker ps | grep primary-1 | cut -b 1-12` bash
   cd /var/lib/postgresql/data/
   mkdir ../backups

Create a replication user on the primary.
You can use any name you want, I am using "dsrepuser" to match ArcGIS DataStore.
In the shell, give dsrepuser permissions,

   psql -U postgres
   CREATE ROLE dsrepuser WITH REPLICATION PASSWORD 'my secret password' LOGIN;

Give the standby (hostname ps) permission to connect for replication.

   echo "" >> ./pg_hba.conf
   echo "# Allow replication from the standby server"  >> ./pg_hba.conf
   echo "host replication dsrepuser ps md5" >> ./pg_hba.conf

### On standby server

**I started gears spinning about how I could automate this entire procedure but
I don't plan on doing it again, and the whole point was not to invent but
to figure out what's going on in ArcGIS DataStore.**

Here we go. Turn the second instance of postgres into a standby / replica server.

Create an image that lets you run utilities without postgres server running; this image has bash set as its entrypoint instead of postgres.

   docker buildx build -t pgutil -f Dockerfile.utilities .

Clear out data on the standby. Since at this point the standby image is running, you can't
remove all its files. Stop everything and use a shell container, as this easiest.

   docker compose down
   docker compose up primary # Primary has to be running so we can run the backup from "standby".
   docker run -it --rm --network postgres-replication_default --hostname ps -v postgres_standby_data:/var/lib/postgresql/data pgutil
   cd /var/lib/postgresql/data
   rm -r *
   # The primary has to be running here! ;-)
   # This command will copy its database files and set up the configuration files for standby replication mode
   # User "dsrepuser" has permission already to work w/o password, we set that in pg_hba.conf above.
   pg_basebackup -h pp -p 5432 -U dsrepuser -D /var/lib/postgresql/data/ -Fp -Xs -R
   rm 000-PRIMARY
   touch 000-STANDBY
   # Bring up all the containers
   docker compose down
   docker compose up -d
   docker compose logs --follow

If you watch the logs you will see the standby container go into standby mode now. Exciting!

BTW here is how to get a shell on a running standby server...

   docker exec -it `docker ps | grep standby-1 | cut -b 1-12` bash

Using the ps command you can see Postgres is *running*, but it is in "walreceiver" mode...

## Testing

Finally I can start testing the running pair of servers. First off, let's look at the process tables.

On "primary",

   docker exec -it `docker ps | grep primary-1 | cut -b 1-12` ps ax
    PID TTY      STAT   TIME COMMAND
      1 ?        Ss     0:00 postgres
     28 ?        Ss     0:00 postgres: checkpointer 
     29 ?        Ss     0:00 postgres: background writer 
     32 ?        Ss     0:00 postgres: walwriter 
     33 ?        Ss     0:00 postgres: autovacuum launcher 
     34 ?        Ss     0:00 postgres: logical replication launcher 

On "standby",

   docker exec -it `docker ps | grep standby-1 | cut -b 1-12` ps ax
    PID TTY      STAT   TIME COMMAND
      1 ?        Ss     0:00 postgres
     28 ?        Ss     0:00 postgres: checkpointer 
     29 ?        Ss     0:00 postgres: background writer 
     30 ?        Ss     0:00 postgres: startup recovering 000000010000000000000003

Oh oh, this is bad, because there is no "wal_receiving" entry. I looked at the logs (docker compose logs) and it tells me stuff like this.

    standby-1  | 2024-03-14 23:34:24.475 UTC [30] LOG:  waiting for WAL to become available at 0/3000210
    primary-1  | 2024-03-14 23:34:24.475 UTC [131] FATAL:  no pg_hba.conf entry for replication connection from host "192.168.48.4", user "dsrepuser", no encryption
    primary-1  | 2024-03-14 23:34:24.475 UTC [131] DETAIL:  Client IP address resolved to "postgres-replication-standby-1.postgres-replication_default", forward lookup not checked.
    primary-1  | 2024-03-14 23:34:29.478 UTC [133] FATAL:  no pg_hba.conf entry for replication connection from host "192.168.48.4", user "dsrepuser", no encryption
    primary-1  | 2024-03-14 23:34:29.478 UTC [133] DETAIL:  Client IP address resolved to "postgres-replication-standby-1.postgres-replication_default", forward lookup not checked.
    standby-1  | 2024-03-14 23:34:29.478 UTC [146] FATAL:  could not connect to the primary server: connection to server at "pp" (192.168.48.3), port 5432 failed: FATAL:  no pg_hba.conf entry for replication connection from host "192.168.48.4", user "dsrepuser", no encryption
    standby-1  | 2024-03-14 23:34:29.479 UTC [30] LOG:  waiting for WAL to become available at 0/3000210

My IP addresses are not stable, because, well, this is Docker and I need to ignore that.
It's telling me it things the standby host's name is "postgres-replication-standby-1.postgres-replication_default" so I will try putting that into pg_hba.conf.
That's the container's name and a dot and the network name. I could I suppose force those to be... shorter? :-) Whatever.

   echo "host replication dsrepuser postgres-replication-standby-1.postgres-replication_default md5" >> ./pg_hba.conf

I had to restart to get it to reread pg_hba.conf but then it popped right up and now the process table has this

    PID TTY      STAT   TIME COMMAND
      1 ?        Ss     0:00 postgres
     28 ?        Ss     0:00 postgres: checkpointer 
     29 ?        Ss     0:00 postgres: background writer 
     30 ?        Ss     0:00 postgres: startup recovering 000000010000000000000003
     33 ?        Ss     0:00 **postgres: walreceiver streaming 0/3000440**

How else can I see what mode it's in though; this works on LINUX but my DataStore is on WINDOWS? There are queries!

On the primary, this command will tell you who is connected

   postgres=# select client_hostname, usename, state from pg_stat_replication;
                          client_hostname                       |  usename  |   state   
   -------------------------------------------------------------+-----------+-----------
    postgres-replication-standby-1.postgres-replication_default | dsrepuser | streaming
   (1 row)

On standby,

   select sender_host, status, conninfo from pg_stat_wal_receiver;

     pp          | streaming | user=dsrepuser password=******** channel_binding=prefer dbname=replication host=pp port=5432 fallback_application_name=walreceiver sslmode=prefer sslcompression=0 sslcertmode=allow sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres gssdelegation=0 target_session_attrs=any load_balance_hosts=disable

### Upload some data and observe replication

### Force failover

## Notes on DataStore


Here is a diff of the postgresql.conf files for datastore on primary and standby, "<" is standby and ">" is primary currently.

    $ diff postgresql.conf.cc-gis*
    258c258
    < restore_command = 'C:/Program^ Files/ArcGIS/DataStore/framework/etc/scripts/dbcli get-transaction-log %f C:/arcgisdatastore/pgdata/%p "C:/Program^ Files/ArcGIS/DataStore/" > nul 2>&1'
    ---
    > #restore_command = ''         # command to use to restore an archived logfile segment
    284c284
    < recovery_target_timeline = 'latest'
    ---
    > #recovery_target_timeline = 'latest'  # 'current', 'latest', or timeline ID
    312c312
    < synchronous_standby_names = ''        # standby servers that provide sync rep
    ---
    > #synchronous_standby_names = ''       # standby servers that provide sync rep
    322c322
    < primary_conninfo = 'host=CC-GISLICENSE.CLATSOP.CO.CLATSOP.OR.US port=9876 user=dsrepuser password=REDACTED'
    ---
    > #primary_conninfo = ''                        # connection string to sending server
    324,325c324,325
    < promote_trigger_file = 'C:/arcgisdatastore/pgdata/promote.done'
    < hot_standby = 'on'                    # "off" disallows queries during recovery
    ---
    > #promote_trigger_file = ''            # file name whose presence ends recovery
    > #hot_standby = on                     # "off" disallows queries during recovery
    393c393
    < effective_cache_size = 12287MB
    ---
    > effective_cache_size = 8191MB
    445c445
    < log_directory = 'C:/arcgisdatastore/logs/CC-GISDATASTORE.CLATSOP.CO.CLATSOP.OR.US/database'
    ---
    > log_directory = 'C:/arcgisdatastore/logs/CC-GISLICENSE.CLATSOP.CO.CLATSOP.OR.US/database'


## Resources

How to set up replication
https://www.digitalocean.com/community/tutorials/how-to-set-up-physical-streaming-replication-with-postgresql-12-on-ubuntu-20-04

Documentation on ArcGIS DataStore is here: 
https://enterprise.arcgis.com/en/data-store/latest/install/windows/welcome-to-arcgis-data-store-installation-guide.htm
