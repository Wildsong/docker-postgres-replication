docker exec -it `docker ps | grep dsprimary | cut -b 1-12` $*
