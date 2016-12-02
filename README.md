# PostgresSQL 9.4 with Bidirectional replication installed as Docker Compose

A Docker Compose configuration that consists of two PostgreSQL 9.4 database instances, both using Bidirectional Replication feature ([BDR site][cc33da40]).

Since there are two separate database instances that depend on each other, some kind of synchronization should be used, so I've used Dockerize ([Dockerize link][77a0257a]) to wait for primary database to be available. However, due to the fact that official PostgreSQL shell script docker-entrypoint.sh run database twice (once to setup initial stuff and another time to actually run the database), plain sleep method is used to wait in combination with Dockerize.

To run it, simply start following command from the directory where docker-compose.yml resides:
```
docker-compose up --build
```
Warning: if secondary BDR node bdr2 complains about not being able to connect to primary BDR node bdr1, it could be that bdr2 builds faster then bdr1 and increase sleep timeout from default 10 seconds.

  [cc33da40]: http://bdr-project.org/docs/stable/index.html "BDR"
  [77a0257a]: https://github.com/jwilder/dockerize "Dockerize"
