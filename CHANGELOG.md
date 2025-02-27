# Changelog

## Unreleased changes

## 5.1.2

- Avoid deadlocks during node shutdown in specific scenarios.
- The node will now shut down to start if an error occurs in a required service
  (e.g., grpc server). In particular, the node will shut down if a required
  service could not be started.
- Add timeout to downloading out of band catchup files when block indices and
  catch-up chunk files are specified by an URL. The timeout is controlled
  by the option `--download-blocks-timeout` (environment variable
  `CONCORDIUM_NODE_CONSENSUS_DOWNLOAD_BLOCKS_TIMEOUT`) and defaults to 5 min.
  timeout is 5 now minutes per chunk instead of waiting indefinitely.
- Remove the "instrumentation" feature of the node and build the node with
  Prometheus support enabled by default.
  - Remove the `CONCORDIUM_NODE_PROMETHEUS_SERVER` environment variable.
    The prometheus server is now started if
    `CONCORDIUM_NODE_PROMETHEUS_LISTEN_PORT` is set.

## 5.1.1

- Relay blocks earlier. In particular this means that blocks are now processed in
  two steps, `block receive` and `block execute`. The former performs verification of block meta data
  while the latter adds the block to the tree.
  Blocks are now enqueued in the outgoing message queue in between the the two steps.
- Removed the configuration option 'no_rebroadcast_consensus_validation'.

## 5.1.0

- Improvements to allow greater concurrency with transaction processing.
  (Checking transaction signatures is done without acquiring the global
  state lock.)

## 5.0.6

- Fix persistent state implementation of contract modifications.
  In certain cases the cached part of the instance was not correctly updated.
- Change the cost of the exchange rate query to be more aligned with other operations.
- Fix the behaviour of a smart contract upgrade when upgrading to a contract
  without entrypoints.

## 5.0.5

- Fix bug in persistent state implementation of contract modification.
- Fix bug in the contract balance query.
- Do not forget logs emitted by smart contracts.

## 5.0.3

- Fix P4->P5 state migration issues.
  - Delegators were not correctly copied over, references were retained to the
    P4 database.
  - Account stake was incorrectly recreated, all account balance was staked.
  - Next payday was incorrectly migrated.

## 5.0.2

- Fix an issue in the node GRPC V2 API where a baker transaction was encoded
  in an unintended way.
- Enforce parameter limits in `InvokeContract` endpoint.

## 5.0.1

- Fix an issue where accounts with scheduled releases would be incorrectly migrated
  on a protocol update.

## 5.0.0

- Add support for protocol version 5. This adds the following features:
  - Support for smart contract upgradability.
  - Query the current exchange rates, account balances and contract balances from a smart contract.
  - Relax restrictions on smart contracts
    - Parameter size limit: 1kiB -> 65kiB
    - Return value size limit: 16kiB -> no limit (apart from energy)
    - Number of logs per invocation: 64 -> no limit (apart from energy)
  - A new representation of accounts that is better optimised for common operations.
  - Revised the hashing scheme for transaction outcomes in protocol version 5.
    In particular the exact reject reasons are no longer part of the computed hash.
    Further the transaction outcomes are being stored in a merkle tree for P5 resulting 
    in some queries being faster.
- More efficient indexing of accounts with scheduled releases.
- Fix an issue where the catch-up downloader would fail at a protocol update.

## 4.5.0

- The node is now able to recover after crashes which leave only treestate or
  only blockstate usable.
- Fix a memory leak that could occur in certain usage scenarios involving smart
  contracts.
- Support for a new GRPC API which uses typed proto definitions. This adds a
  number of new configuration options for the node. These are detailed in
  [grpc2.md](https://github.com/Concordium/concordium-node/blob/main/docs/grpc2.md)

## 4.4.4

- Fix a bug in database recovery where the node would hang when truncating the block state database
  on Windows.

## 4.4.3

- Fix a bug in database recovery where corruption was not always correctly detected.
- Fix typo in environment variable `CONCORDIUM_NODE_PROMETHEUS_LISTEN_ADDRESSS` (remove trailing `S`).

## 4.4.2

- Speed up and reduce memory overhead during protocol updates.

- Smart contract modules are no longer retained in memory. Module artifacts are loaded as needed
  during contract execution. Metadata is cached for a limited number of smart contract modules.
  By default, the cache will retain metadata for at most 1000 smart contract modules, and this is
  configurable via the `--modules-cache-size` command line argument or by using the 
  `CONCORDIUM_NODE_CONSENSUS_MODULES_CACHE_SIZE` environment variable.

- Smart contract state is no longer cached on startup and is not cached after
  finalization.

- Partial node database recovery. The node is now able to recover from the most
  common causes of its database corruption.

## 4.4.1

- Verify pending blocks earlier when possible.
- Do not relay pending blocks.

## 4.4.0

- Fix a bug in Ctrl-C signal handling where a node would fail to stop if
  interrupted early on in the startup if out-of-band catchup was enabled.
- `database-exporter` now produces a collection of export files, instead of a single file. The new
  `--chunksize` option specifies the size of export files in blocks.
- The `--download-blocks-from` option now takes the URL to the catchup _index file_, permitting to
  only download and import catchup files containing blocks not already present in the database.

## 4.3.1

- Improvements to start-up time that fix regressions introduced by the account caching.

## 4.3.0

- Account records are no longer constantly retained in memory. Instead a limited
  number are retained in a cache. The number of cached accounts defaults to 10000,
  and can be configured by the `--accounts-cache-size` command line argument or the
  `CONCORDIUM_NODE_CONSENSUS_ACCOUNTS_CACHE_SIZE` environment variable.
- Reduce startup time and memory use further by reducing the amount of block
  data retained in memory. In particular finalized blocks are no longer stored
  in memory.
- Optimize node data structures related to accounts. This reduces node memory
  use and improves performance.
- Added the ability to download the catch-up file using the
  `--download-blocks-from` option (or `CONCORDIUM_NODE_CONSENSUS_DOWNLOAD_BLOCKS_FROM` environment variable).
- The gRPC API now reports correctly when the sender of a transaction did
  not have enough funds to cover the transaction costs.
- Remove obsolete and unused option `--max-expiry-duration`
- Remove transaction logging functionality from the node. It is replaced by an
  external service. As a consequence the `transaction-outcome-logging` family of
  command-line options are removed from the node.

## 4.2.3

- Fix a bug in the scheduler which would cause the node to crash when executing
  certain transactions. [Security advisory](https://github.com/Concordium/concordium-node/security/advisories/GHSA-44wx-3q8j-r8qr)

## 4.2.1

- Decrease node startup time and memory use by avoiding needless checks when
  loading the database.
- Improve startup time by avoiding processing already processed protocol
  updates.
- Decrease memory usage by not storing genesis blocks. This has the effect that
  the database produced by node versions >= 4.2.* cannot be used by node
  versions <= 4.1. The other direction works.
- Increase precision of block arrive and block receive times in the
  `GetBlockInfo` query.

## 4.1.1
- The `SendTransaction` function exposed via the gRPC interface now provides the caller with detailed error messages if the 
  transaction was rejected instead of just `False`. The function still returns `True` if 
  the transaction was accepted.
  The following gRPC error codes can be returned.
  - 'SUCCESS' The transaction was succesfully relayed to consensus.
  - 'INVALID_ARGUMENT' The transaction was deemed invalid or exceeds the maximum size allowed (the raw size of the transaction).
     In addition the error message contains information as to why the transaction was deemed invalid.
  - 'FAILED_PRECONDITION' The network was stopped due to an unrecognized protocol update.
  - 'DUPLICATE_ENTRY' The transaction was a duplicate.
  - 'INTERNAL' An internal error happened and as such the transaction could not be processed.
  The server will return a gRPC status if the transaction was deemed invalid. 
- Support for wire-protocol version 0 is dropped, meaning that the node cannot
  connect to peers that do not support wire-protocol version 1, which is supported
  since version 1.1.0.
- The macOS installer no longer overwrites the service files when reinstalling.
- Cache smart contract modules on startup from existing state to improve smart
  contract execution.
- Make consensus queries more robust, by validating input more extensively.
  This affects all queries whose input was a block or transaction hash.
  These queries now return `InvalidArgument` error, as opposed to `Unknown`
  which they returned previously.
- Fix issue #244: Collector to keep querying. Remove the parameter for maximum allowed
  times a gRPC call can fail and keeps `node-collector` querying forever.
- `GetAccountInfo` endpoint supports querying the account via the account index.
- Mac installer: Users now can leave one (but not both) of the net configurations empty
  when they don't want to configure a node for it.
  - On the initial installation, leaving a net configuration empty means that
    the start/stop app shortcuts and the application support folder for that net won't be installed.
- Implement baker pools and stake delegation for the P4 protocol version.
  - New gRPC endpoint: `GetBakerList` retrieves a JSON list of the baker IDs of the bakers
    registered in a known block. (Returns `null` for an unknown block.)
  - New gRPC endpoint: `GetPoolStatus` retrieves a status record for a baker pool, or for
    the set of passive delegators.
  - The `bakerStakeThreshold` level-2 keys are renamed as the `poolParameters` keys; two
    additional access structures are defined: `cooldownParameters` and `timeParameters`.
  - The following changes are made to the chain parameters in P4:
    - The mint distribution no longer includes the mint per slot rate.
    - Pool parameters are added, governed by the `poolParameters` keys, that determine
      commission rates and ranges, bounds and other factors affecting baker pools.
    - Time parameters, governed by `timeParameters`, are added that determine the
      duration of a payday (in epochs) and the mint rate per payday.
    - Cooldown parameters, governed by `cooldownParameters`, are added that determine
      the required cooldown periods when bakers and delegators reduce their stakes.
  - ConfigureBaker and ConfigureDelegator transactions are added (with the old baker
    transactions becoming obsolete in P4). These permit adding, modifying and removing bakers
    and delegators respectively from an account. Delegators can delegate to a baker, or
    delegate passively (effectively to all bakers).
  - The reward mechanism is overhauled, with minting and rewarding being done once per
    'payday' (a number of epochs, nominally one day). Baker rewards are shared with
    delegators to the baker's pool, with some commission being paid to the baker.
    Block rewards (i.e. transaction fee rewards), baking rewards and finalization rewards
    are accumulated over the reward period and paid out at the payday.
- Implement V1 smart contracts with the following key features
  - unlimited contract state size
  - synchronous contract calls
  - fallback entrypoints
  - increased smart contract module size limit, 512kB
  - a number of cryptographic primitives
- Node can now be stopped during out of band catchup by using signals, SIGINT and SIGTERM.

## concordium-node 3.0.1

- Fix a starvation bug in some cases of parallel node queries.

## concordium-node 3.0.0

- Fix a bug due to incorrect use of LMDB database environments where a node
  would crash if queried at specific times.
- Faster state queries by avoiding locking the block state file when reading.
- Fix a bug by shutting down RPC before the node, which caused the node to crash
  when attempting a graceful shutdown while processing RPC requests.
- Introduce support for account aliases via protocol P3. Accounts can be queried
  in `GetAccountInfo`, `GetAccountNonFinalizedTransactions`,
  `GetNextAccountNonce` by any alias.
- `GetAccountInfo` object has an additional field `accountAddress` that contains
  the canonical address of the account.
- The node now drops all connections on an unrecognized protocol update and
  refuses to accept new transactions.

## concordium-node 1.1.3

- Fix a number of bugs that led to node crashes due to failed block lookup in some situations.
- Support custom path for genesis data via `CONCORDIUM_NODE_CONSENSUS_GENESIS_DATA_FILE`.

## concordium-node 1.1.2

- Fix regression where expired transactions were not immediately rejected.

## concordium-node 1.1.1

- Fix response of the transaction status query. Due to incorrect serialization
  the response was incorrectly reported as finalized even if transaction was
  only committed.
- For macOS:
  - Added option to use the native mac logging system. To enable it, provide
    the new flag `--use-mac-log <subsystem-name>`. The flag is available on both
    the node and collector with corresponding, respective, environment variables
    `CONCORDIUM_NODE_MACOS_USE_MAC_LOG` and `CONCORDIUM_NODE_COLLECTOR_USE_MAC_LOG`.
  - When the flag is provided, you can view the logs with `log show --predicate
    'subsystem == "<subsystem-name>"'`, or by using Console.app. 

## concordium-node 1.1.0

- Node improvements and new features
  - Update dependencies, code cleanup, and removal of the staging_net feature.
  - Fix a bug in average throughput calculation that was triggered in some cases
    of bad connectivity.
  - Add support for configuring the node and the collector via environment
    variables in addition to command line arguments. This is a breaking change in
    that flags now need to have an explicit argument.
  - Remove use of `unbound` for DNS resolution. This also removes the dnssec functionality, and the
    flag `--no-dnssec` is no longer supported. The command-line option `--resolv-conf` is also
    removed, as the system resolver will be used.
  - Introduce protocol P2 that supports transfers with memo.
  - Implement protocol updates, allowing migration to a new protocol. Two protocol updates are
    implemented. One which does not switch to a new protocol version, but allows for updating a number
    of genesis parameters that would otherwise be immutable, while retaining the
    state. A second protocol update updates from P1 to P2.
  - Reduced logging of certain events. Received blocks, finalization messages/records, and
    transactions are only logged at Trace level. GRPC queries are not logged.
  - Support [log4rs](https://docs.rs/log4rs/1.0.0/log4rs/) logging, by specifying a configuration file
    (in toml or yaml format) with the `--log-config` argument or `CONCORDIUM_NODE_LOG_CONFIG`
    environment variable.
  - A Windows node runner service and installer.
    See [service/windows/README.md](service/windows/README.md).

- Network API changes
  - Remove unused `--bootstrap-server` flag.
  - Support for a new wire-protocol version (version 1) that adds a genesis index to non-transaction
    messages, a version header to catch-up messages. Version 0 is still supported for communication
    with legacy nodes during migration.
  - Relax compatibility check so that the node only checks a lower bound on the
    peer major version, in contrast to requiring an exact major version match.

- Database changes
  - Global state database now includes version metadata. The treestate directory and blockstate file
    names are suffixed with "-*n*" to indicate genesis index *n*.
    A legacy database will automatically be migrated by renaming and adding version metadata.
  - Change the automatically created indices on the transaction logging database.
    Instead of an index on the `id` column on `ati` and `cti` tables there are now
    multi-column indices that better support the intended use-cases. This only
    affects newly created databases.
  - The block export format has been revised to a new version (version 3) which allows for
    protocol updates. Version 2 is no longer supported.

- GRPC API changes
  - In the GetRewardStatus GRPC call, the amounts that were previously represented as integers are now
    represented as strings in the JSON serialization. This is in line with how amounts are serialized
    elsewhere.
  - The behaviour of GetAccountList, GetInstances, and GetModuleList have changed in the case
    where the block hash is ill-formed. Instead of returning the JSON string "Invalid block hash.",
    these functions will now return the JSON null value.
  - GetConsensusStatus return value has additional fields to indicate the protocol
    version and effected protocol updates.
  - GetBlockInfo return value has additional fields indicating the genesis index and local height
    (relative to the genesis block at the genesis index) of the block. The block height reported
    is absolute. The reported parent of a re-genesis block will be the last final block of the
    preceding chain, so the absolute height indicates how many times the parent pointer should be
    followed to reach the initial genesis.
  - GetBlocksAtHeight supports specifying a genesis index, with the supplied height being treated as
    relative to the genesis block at that index. An additional flag allows restricting the query to
    just that index.

## concordium-node 1.0.1

- Check that baker keys are consistent (private key matches the public one) on startup.
- Prevent rebroadcast of catch-up status messages.

## concordium-node 1.0.0

- Expose accountIndex in the `getAccountInfo` query.
- Fix serialization bug in smart contracts get_receive_sender when the address
  is that of an account.

## concordium-node 0.7.1

- Make sure to not rebroadcast transactions that consensus marked as not
  rebroadcastable.
- Fix command-line parsing issue in concordium-node related to --import-blocks-from.

## concordium-node 0.7.0

Start of changelog.
