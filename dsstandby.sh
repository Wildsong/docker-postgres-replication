docker exec -it `docker ps | grep dsstandby | cut -b 1-12` $*
