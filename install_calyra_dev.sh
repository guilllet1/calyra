services:
  postgres:
    image: postgres:15
    container_name: postgres
    restart: always
    environment:
      POSTGRES_USER: camunda
      POSTGRES_PASSWORD: VkhryZ2m3tWVSm03lUkw
      POSTGRES_DB: camunda
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "camunda"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7
    container_name: redis
    restart: always
    volumes:
      - ./data/redis:/data
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  mongodb:
    image: mongo:6
    container_name: mongodb
    restart: always
    command: ["--replSet", "rs0", "--bind_ip_all", "--keyFile", "/data/key/mongodb-keyfile"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: appsmith
      MONGO_INITDB_ROOT_PASSWORD: kxlbLydIOYiw62ANigbg
    volumes:
      - ./data/mongo:/data/db
      - ./data/mongo_key:/data/key
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD-SHELL", "mongosh -u appsmith -p kxlbLydIOYiw62ANigbg --authenticationDatabase admin --quiet --eval 'try { rs.status() } catch (e) { quit(1) }; quit(0)'"]
      interval: 10s
      timeout: 5s
      retries: 10  # Plus de retries pour donner du temps à l'init

  appsmith:
    image: appsmith/appsmith-ce
    container_name: appsmith
    restart: always
    depends_on:
      redis:
        condition: service_healthy
      mongodb:
        condition: service_healthy
    environment:
      - APPSMITH_REDIS_URL=redis://redis:6379
      - APPSMITH_MONGODB_URI=mongodb://appsmith:kxlbLydIOYiw62ANigbg@mongodb:27017/appsmith?authSource=admin&replicaSet=rs0
      - APPSMITH_DISABLE_TELEMETRY=true
      - APPSMITH_MAIL_ENABLED=false
      - APPSMITH_CUSTOM_DOMAIN=https://appsmith.ddns.net
      - APPSMITH_ROOT_REDIRECT_URL=/
    volumes:
      - ./data/appsmith-stacks:/appsmith-stacks
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD", "wget", "--spider", "localhost:80"]
      interval: 10s
      timeout: 5s
      retries: 5

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.8.0  # Aligné avec Camunda version
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - network.host=0.0.0.0
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
    user: "1000:1000"
    volumes:
      - ./data/elasticsearch:/usr/share/elasticsearch/data
    healthcheck:
      test: ["CMD-SHELL", "curl -fsSL http://localhost:9200/_cluster/health || exit 1"]
      interval: 20s
      timeout: 10s
      retries: 50
    networks:
      - calyra_net

  camunda:
    image: camunda/zeebe:8.8.0
    container_name: camunda
    restart: always
    environment:
      - ZEEBE_BROKER_CLUSTER_PARTITIONSCOUNT=1
      - ZEEBE_BROKER_CLUSTER_REPLICATIONFACTOR=1
      - ZEEBE_BROKER_CLUSTER_CLUSTERSIZE=1
      - ZEEBE_BROKER_EXPORTERS_ELASTICSEARCH_CLASSNAME=io.camunda.zeebe.exporter.ElasticsearchExporter
      - ZEEBE_BROKER_EXPORTERS_ELASTICSEARCH_ARGS_INDEX_PREFIX=zeebe-record
      - ZEEBE_BROKER_EXPORTERS_ELASTICSEARCH_ARGS_BULK_DELAY=5
      - ZEEBE_BROKER_GATEWAY_NETWORK_HOST=0.0.0.0
      - SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/camunda
      - SPRING_DATASOURCE_USERNAME=camunda
      - SPRING_DATASOURCE_PASSWORD=VkhryZ2m3tWVSm03lUkw
    depends_on:
      postgres:
        condition: service_healthy
      elasticsearch:
        condition: service_healthy
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD-SHELL", "timeout 3 bash -c '</dev/tcp/localhost/26500' && echo OK || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 30
      start_period: 60s

  operate:
    image: camunda/operate:8.8.0
    container_name: operate
    depends_on:
      elasticsearch:
        condition: service_healthy
      camunda:
        condition: service_healthy
    environment:
      - CAMUNDA_OPERATE_ELASTICSEARCH_URL=http://elasticsearch:9200
      - CAMUNDA_OPERATE_ZEEBE_GATEWAYADDRESS=camunda:26500
      - CAMUNDA_DATA_SECONDARY_STORAGE_ELASTICSEARCH_URL=http://elasticsearch:9200
    entrypoint: >
      /bin/sh -c "
        echo 'Waiting for Elasticsearch...';
        until wget -q --spider http://elasticsearch:9200; do
          sleep 5;
        done;
        echo 'Elasticsearch ready. Starting Operate...';
        exec /usr/local/operate/bin/operate;
      "
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider localhost:8080 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5

  nginx:
    image: nginx:latest
    container_name: nginx
    restart: always
    depends_on:
      appsmith:
        condition: service_healthy
      operate:
        condition: service_healthy
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./certs:/etc/ssl/private
    ports:
      - "80:80"
      - "443:443"
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD", "wget", "--spider", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

networks:
  calyra_net:
    driver: bridge
