# docker-postgres

Postgres 15 and pgadmin4 running in docker containers in perfect harmony.

In fact, TWO COPIES of Postgres, with data replication!

There's a Dockerfile and we build our own image because we want to use this with
Esri as an Enterprise Geodatabase Server so it needs to have st_geometry.so
installed. That's also why the "old" version of Postgres.

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

Copy sample.env to .env and then edit it to set a
username and password.

### Build Docker images

    docker compose build

## Deploy

### Start

    docker compose up -d

### Stop

    docker compose down

## Access

You should be able to connect to the pgadmin instance on
http://localhost:8213/

The primary database runs on port 5432 and the standby, on port 5433.
