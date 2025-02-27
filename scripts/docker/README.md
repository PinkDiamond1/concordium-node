# Dockerized components

The dockerfiles in this folder are used to build images for each of the components:

- `node`
- `bootstrapper`
- `node-collector`

All the components are compiled (in both release and debug) in a monolithic image from the dockerfile `universal.Dockerfile`.
The other dockerfiles just extract the individual binaries from this image, install dependencies, and declare exposed ports.

To run the node, the genesis file `genesis.dat` needs to be placed at the data path when the node starts.
One way to do this is to inject the file as a bind mount as shown in the example below.

## Jenkins Pipelines

The node-related binaries are built by the pipeline `master.Jenkinsfile` in the `jenkinsfiles` top-level folder.

## Docker Compose

The following example shows a (reasonably) minimal configuration of a node and an accompanying collector:

```yaml
version: '3'
services:
  node:
    container_name: node
    image: ${NODE_IMAGE}
    networks:
    - concordium
    environment:
    - CONCORDIUM_NODE_CONNECTION_BOOTSTRAP_NODES=bootstrap.${DOMAIN}:8888
    - CONCORDIUM_NODE_DATA_DIR=/mnt/data
    - CONCORDIUM_NODE_CONFIG_DIR=/mnt/config
    - CONCORDIUM_NODE_CONSENSUS_GENESIS_DATA_FILE=/mnt/genesis.dat
    - CONCORDIUM_NODE_BAKER_CREDENTIALS_FILE=/mnt/baker-credentials.json
    - CONCORDIUM_NODE_RPC_SERVER_ADDR=0.0.0.0
    - CONCORDIUM_NODE_GRPC2_LISTEN_ADDRESS=0.0.0.0
    - CONCORDIUM_NODE_GRPC2_LISTEN_PORT=20000
    ports:
    - "8888:8888"
    - "10000:10000"
    - "20000:20000"
    volumes:
    - ${GENESIS_DATA_FILE}:/mnt/genesis.dat
    - ${BAKER_CREDENTIALS_FILE}:/mnt/baker-credentials.json
    - data:/mnt/data
    - config:/mnt/config
  node-collector:
    container_name: node-collector
    image: ${NODE_COLLECTOR_IMAGE}
    depends_on:
    - node
    networks:
    - concordium
    environment:
    - CONCORDIUM_NODE_COLLECTOR_URL=http://dashboard.${DOMAIN}/nodes/post
    - CONCORDIUM_NODE_COLLECTOR_GRPC_HOST=http://node:10000
    - CONCORDIUM_NODE_COLLECTOR_NODE_NAME=${NODE_NAME}
volumes:
  data:
  config:
networks:
  concordium:
```

Run the deployment using `docker-compose`; for example:

```shell
export NODE_NAME="<name>"
export NODE_IMAGE="concordium/node:<tag>"
export NODE_COLLECTOR_IMAGE="concordium/node-collector:<tag>"
export DOMAIN=mainnet.concordium.software # alternative values: 'stagenet.concordium.com', 'testnet.concordium.com'
export GENESIS_DATA_FILE="/absolute/path/to/genesis.dat"
export BAKER_CREDENTIALS_FILE="/absolute/path/to/baker-credentials.json"
docker-compose up
```
