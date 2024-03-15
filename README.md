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

### Start again

If I made major changes and I want to start my tests again, I can just remove the existing volumes now.
Of course, if you have already painstakingly loaded data in, it will all be gone.

   docker volume rm postgres_data
   docker volume rm postgres_standby_data
   docker volume rm pgadmin_data

## Deploy

### Start

If this the first time, create the pgadmin volume. It's shared with other projects so it's external.

   docker volume create pgadmin_data

Then start everything so the postgres data volumes get created.

   docker compose up -d

This should start two instances of Postgres, in compose.yam hostname are set to "dsprimary" and "dsstandby".
Setting container_name and the network name in compose.yaml gives us manageable hostnames like 
"dsprimary.datastore" to use in our config files.

The primary database is exposed locally on port 5432. The standby is not, since it only communicates
internally with pgadmin and dsprimary.

Once it's started I usually track the logs with

    docker compose logs --follow

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

I have a couple helper scripts, dsprimary.sh and dsstandby.sh
They look up the id of a container, and run a command in that container.

Create a replication user on the primary.
You can use any name you want, I am using "dsrepuser" to match ArcGIS DataStore.
In the shell, give dsrepuser permissions,

   ./dsprimary.sh psql -U postgres
   CREATE ROLE dsrepuser WITH REPLICATION PASSWORD 'my secret password' LOGIN;
   CREATE ROLE

Give the standby (hostname ps) permission to connect for replication.
Also give a user named 'sde' permission to connect, we will need this later as
we enter the Esri universe. You could lock sde to a single database or host
but this is just an experiment so we're not worried about it.

   ./dsprimary.sh bash
   echo "" >> ./pg_hba.conf
   echo "# Allow replication from the standby server"  >> ./pg_hba.conf
   echo "host replication dsrepuser dsstandby.datastore md5" >> ./pg_hba.conf
   echo "" >> ./pg_hba.conf
   echo "# Allow the Esri user to connect and manage a database"  >> ./pg_hba.conf
   echo "host all sde samenet md5" >> ./pg_hba.conf

### On standby server

**I started gears spinning about how I could automate this entire procedure but
I don't plan on doing it again, and the whole point was not to invent but
to figure out what's going on in ArcGIS DataStore.**

Here we go: Turn the second instance of postgres into a standby / replica server.

Create an image that lets you run utilities without postgres standby server running; this image has bash set as its entrypoint instead of postgres, so it launches directly into a shell.

   docker buildx build -t pgutil -f Dockerfile.utilities .

Clear out data on the standby.

   docker compose down
   docker compose up primary -d # Primary has to be running so we can run the backup from "standby".
   docker run -it --rm --network datastore --name dsstandby -v postgres_standby_data:/var/lib/postgresql/data pgutil
   cd $PGDATA && rm -r *
   # The primary has to be running here! ;-)
   # This command will copy its database files and set up the configuration files for standby replication mode
   # User "dsrepuser" has permission already to work w/o password, we set that in pg_hba.conf above.
   pg_basebackup -h dsprimary -p 5432 -U dsrepuser -D $PGDATA -Fp -Xs -R
   PASSWORD: # enter your password here... the one you used in the primary set up CREATE ROLE command.
   exit # exit the container shell

 Bring up all the containers normally

   docker compose down
   docker compose up -d
   docker compose logs --follow

If you watch the logs you will see the standby container go into standby mode now. Exciting!

#### Database access via browser

Launching via compose also starts pgadmin. You can access pgadmin on port 8213, i.e.
http://localhost:8213/browser/ -- please note it's not encrypted and you have
to send usernames and passwords over it to use it.

You have to set a password on the postgres account on the primary machine before you can log in from pgadmin.
You can't write changes now to standby since it's in read-only mode. It will pick up changes made to dsprimary.

   ./dsprimary.sh psql -U postgres postgres 
   ALTER USER postgres WITH PASSWORD 'your password here';

In pgadmin, you have to set up connections to "dsprimary" and "dsstandby".
Even though you did not set credentials on dsstandby, you can still set up a connection
and monitor it. The password for dsprimary will have automatically been copied over. Magic.

## Testing

Finally I can start testing the running pair of servers. First off, let's look at the process tables.

On "primary",

    ./dsprimary.sh ps ax
    PID TTY      STAT   TIME COMMAND
      1 ?        Ss     0:00 postgres
     28 ?        Ss     0:00 postgres: checkpointer 
     29 ?        Ss     0:00 postgres: background writer 
     32 ?        Ss     0:00 postgres: walwriter 
     33 ?        Ss     0:00 postgres: autovacuum launcher 
     34 ?        Ss     0:00 postgres: logical replication launcher 

On "standby", you should now see Postgres is *running*, but it is in "walreceiver" mode...

   ./dsstandby.sh ps ax
    PID TTY      STAT   TIME COMMAND
      1 ?        Ss     0:00 postgres
     29 ?        Ss     0:00 postgres: checkpointer 
     30 ?        Ss     0:00 postgres: background writer 
     31 ?        Ss     0:00 postgres: startup recovering 000000010000000000000003
     32 ?        Ss     0:01 postgres: walreceiver streaming 0/3000C50
     47 ?        Ss     0:00 postgres: postgres postgres 192.168.144.2(55814) idle
     48 pts/0    Rs+    0:00 ps ax

The first time I set this up, I had the hostname in pg_hba.conf wrong! So I had to go back and add it.
The clue was in the log files, it kept saying things like this. It motivated me to change compose.yaml
as noted above to give it a more consistent and readable hostname.

    primary-1  | 2024-03-14 23:34:24.475 UTC [131] FATAL:  no pg_hba.conf entry for replication connection from host "192.168.48.4", user "dsrepuser", no encryption
    primary-1  | 2024-03-14 23:34:24.475 UTC [131] DETAIL:  Client IP address resolved to "postgres-replication-standby-1.postgres-replication_default", forward lookup not checked.

Docker IP addresses are not stable, because, well, this is Docker and I need to ignore that reference to 192.168...
After adding a proper hostname (which used to be "postgres-replication-standby-1"), I had to restart the container
to get postgres to reread pg_hba.conf but then the connection popped right up.

How else can I see what mode it's in though; peeking at the process table works on LINUX 
but my ArcGIS DataStore is on WINDOWS? There are SQL queries!
It seems like with PostgreSQL anyway, there are queries for ALL its configuration settings. Handy.

On the primary, this select query will tell you who is connected

   ./dsprimary.sh psql -U postgres
   postgres=# select client_hostname, usename, state from pg_stat_replication;
                          client_hostname                       |  usename  |   state   
   -------------------------------------------------------------+-----------+-----------
    postgres-replication-standby-1.postgres-replication_default | dsrepuser | streaming
   (1 row)

On standby, this select tells you who is the primary,

   ./dsstandby.sh psql -U postgres
   select sender_host, status, conninfo from pg_stat_wal_receiver;

     dsprimary   | streaming | user=dsrepuser password=******** channel_binding=prefer dbname=replication host=dsprimary port=5432 fallback_application_name=walreceiver sslmode=prefer sslcompression=0 sslcertmode=allow sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres gssdelegation=0 target_session_attrs=any load_balance_hosts=disable

I know replication works because it replicated my postgres password. It is now
set to replicate EVERY database change from dsprimary to dsstandby. But I want to do more tests.

### TEST: Create an Enterprise Geodatabase

To use it as an Esri geodatabase in ArcGIS Pro, 
I have to use the tool "Create Enterprise Geodatabase", see https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/create-enterprise-geodatabase.htm I can run this from either ArcGIS Pro or from a Python environment 
where arcpy is installed. You know what *I* what to do. First off I need an account in the database, called 'sde', 
because, well; it's traditional. Supposedly you don't have to create a database or give sde any
additional permissions because that will be handled in the next step. It failed. I had to make sde a "superuser".

   ./dsprimary.sh psql -U postgres postgres
   CREATE USER sde WITH PASSWORD 'SDE password';
   ALTER ROLE sde WITH SUPERUSER;

Of course I have to put sde into the pg_hba.conf table; but I did that way back up in the primary setup section,
against future need. You will need the "keycodes" fiile which you can copy from your existing ArcGIS server.
Look for C:/Program Files/ESRI/License11.2/sysgen/keycodes on a machine running ArcGIS Server.

Supposedly I can run this directly in Python on my Desktop. It failed, I used the GUI in ArcGIS Pro.

    conda activate arcgispro-py3
    python
    import arcpy
    arcpy.management.CreateEnterpriseGeodatabase('PostgreSQL', 'cc-testmaps.co.clatsop.or.us', 'clatsop','DATABASE_AUTH','postgres','postgres password','SDE_SCHEMA','sde', 'SDE password',authorization_file='keycodes')

As the tool in ArcGIS Pro ran, I watched about 100 error messages flash by in the Postgres log. Then it said "completed".
There is now a "clatsop" database in both dsprimary and dsstandby.

### TEST: Upload some data and observe replication

Doing "New Database Connection" in the ArcGIS Pro Catalog worked.

Next I imported a shapefile from catalog and worked too.

Then I added the feature class in the database to a map, and that worked.

I can see the feature class now in pgadmin too, as a table. Cool. And it's in dsstandby. Cool again.
I wish there was a spatial viewer plugin or something in pgadmin; the "shape" column shows type "st_geometry"
but shows only as a string of hex data.

### TEST: Force failover

What happens if the primary fails? I want to be able to update my connection in Pro to the standby
and press on

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
