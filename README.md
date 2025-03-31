# CDC-PostgreSQL-ClickHouse

Below you find a full CDC setup between PostgreSQL & ClickHouse, using Kafka Connect as a middle man. The setup is fully built on the Aiven platform.

## Database setup

### Prerequisite
- You have full access to an active [Aiven for PostgreSQL](https://aiven.io/postgresql) service

### PostgreSQL setup

Below is the basic schema of our bookings table in PostgreSQL:

```sql
CREATE TABLE bookings (
	id SERIAL PRIMARY KEY, 
	booking_id VARCHAR(50) NOT NULL,
	status TEXT NOT NULL,
	is_deleted boolean,
	is_canceled boolean,
	created_at TIMESTAMP DEFAULT timezone('UTC', CURRENT_TIMESTAMP),
	modified_at TIMESTAMP DEFAULT timezone('UTC', CURRENT_TIMESTAMP)
);
```

We have to set the REPLICA IDENTITY to `full` so that Debezium will forward both the `before` & `after` values for any changed row. 

```sql
ALTER TABLE bookings REPLICA IDENTITY FULL;
```

## ClickHouse

### Prerequisite
- You have full access to an active [Aiven for ClickHouse](https://aiven.io/clickhouse) service

### ClickHouse setup

#### Main table
We now create a bookings table which reflects the schema of the PostgreSQL table:

```sql
CREATE TABLE default.bookings 
(
	`booking_id` String,
	`status` String,
	`is_deleted` UInt8,
	`is_canceled` Bool,
	`created_at` DateTime('UTC'),
	`modified_at` DateTime('UTC'),
	`version` UInt64, 
)
ENGINE = ReplacingMergeTree(version, is_deleted)
PRIMARY KEY booking_id
ORDER BY booking_id
```

There are a number of relevant ClickHouse-related things to mention here:
- The Table Engine used is `ReplacingMergeTree`. This allows us to use ClickHouse's internal merging capabilities to support change operations (INSERTS, UPDATES, DELETES). For more information, see: https://clickhouse.com/docs/guides/replacing-merge-tree
	- Entries are uniquely identified by the `booking_id` (`ORDER BY` clause)
	- The latest version is determined by a `version` column. This column is updated based on the latest LSN sequence number (see Materialised View setup below). 
	- Deletes are supported by writing to a `is_deleted` column. If set to 1, ClickHouse will take care to remove the respective entry during it's data part merge process. 

#### Supporting tables
In order to enable a full flow from PostgreSQL --> Debezium (Kafka Connect) --> Kafka --> ClickHouse Sink (Kafka Connect) --> ClickHouse, we will need two more tables that will help us to transform the data coming from Debezium and write it to our main `bookings` table. 

First, we create a `bookings_changes` table. This is the table to which the ClickHouse Sink connector will send the data. Debezium sends the data in a nested JSON format. Since we have set `REPLICA IDENTITY` to `full`, we will receive both the `before` & `after` values of the changed rows. 

As you can see in the schema, we directly replicate the `JSON` format: 
```sql
CREATE TABLE bookings_changes
(
	`before.id` UInt64,
	`before.booking_id` String,
	`before.status` String,
	`before.is_deleted` UInt8,
	`before.is_canceled` Bool,
	`before.created_at` Int64,
	`before.modified_at` Int64,
	`after.id` UInt64,
	`after.booking_id` String,
	`after.status` String,
	`after.is_deleted` UInt8,
	`after.is_canceled` Bool,
	`after.created_at` Int64,
	`after.modified_at` Int64,
	`op` LowCardinality(String), 
	`ts_ms` UInt64, 
	`source.sequence` String, 
	`source.lsn` UInt64
)
ENGINE = MergeTree 
ORDER BY tuple()
```

 We have also added some relevant additional columns here:
- `op` : this indicates the operation; the values `u`, `d`, and `c` are indicating an *update*, *delete* and *insert* operation, respectively. 
- `source.lsn`: as already mentioned above, we will use the LSN to determine the latest version per record. 

As this message format is not directly compatible with our `bookings` table, we now need a way to transform the messages coming into `bookings_changes` and write them to our final `bookings` table. 

ClickHouse provides us with a convenient option here: (Incremental) [Materialized Views](https://clickhouse.com/docs/materialized-view/incremental-materialized-view). A Materialized View allows us to select the relevant fields from `bookings_changes` and update the columns depending on the operation (`delete` requires slightly different updates as the other table updates):

```sql
CREATE MATERIALIZED VIEW bookings_mv TO bookings
	(
	`booking_id` String,
	`status` String,
	`is_deleted` UInt8,
	`is_canceled` Bool,
	`created_at` DateTime64,
	`modified_at` DateTime64,
	`version` UInt64
	) AS 
	SELECT 
		if(op = 'd', before.booking_id, after.booking_id) AS booking_id, 
		if(op = 'd', before.status, after.status) AS status, 
		if(op = 'd', 1, 0) AS is_deleted, 
		if(op = 'd', before.is_canceled, after.is_canceled) AS is_canceled, 
		if(op = 'd', fromUnixTimestamp64Micro(before.created_at), fromUnixTimestamp64Micro(after.created_at)) AS created_at, 
		if(op = 'd', fromUnixTimestamp64Micro(before.modified_at), fromUnixTimestamp64Micro(after.modified_at)) AS modified_at, 
		if(op = 'd', source.lsn, source.lsn) AS version
	FROM default.bookings_changes
	WHERE (op = 'c') OR (op = 'r') OR (op = 'u') OR (op = 'd')
```

### Initial Data Load

#### PostgreSQL

> *The exact value for the columns isn't relevant at the moment as this is just meant to illustrate the flow.*

Below is an initial load of 10 rows. The status in use is one of:
- *Open*
- *Created*
- *In Progress*
- *Delayed*
- *Completed*
- *Cancelled*

```sql
INSERT INTO bookings (booking_id, status, is_deleted, is_canceled) VALUES 
('b1', 'Open', 'False', 'False'),
('b2', 'Created', 'False', 'False'), 
('b3', 'In Progress', 'False', 'False'),
('b4', 'In Progress', 'False', 'False'),
('b5', 'Delayed', 'False', 'False'),
('b6', 'Delayed', 'False', 'False'),
('b7', 'Completed', 'False', 'False'),
('b8', 'Cancelled', 'False', 'True'),
('b9', 'Cancelled', 'False', 'True'),
('b10', 'Completed', 'False', 'False');
```

#### ClickHouse
In order to have both data sets be the same, we can just load it directly from PostgreSQL into ClickHouse:

```sql
INSERT INTO bookings SELECT 
	booking_id,
	status,
	is_deleted,
	is_canceled,
	created_at, 
	modified_at,
	1 AS version
	FROM postgresql('<host>:<port>', 'defaultdb', 'bookings', '<user>', '<password>')
``` 

We're now ready to set up Kafka & Kafka Connect.

## Kafka setup
### Prerequisite
- You have full access to an active [Aiven for Kafka](https://aiven.io/kafka) service
- You have created a standalone [Aiven for Apache Kafka Connect](https://aiven.io/docs/products/kafka/kafka-connect/get-started)  service

### Connectors
#### Debezium Source Connector
The Debezium Source connector will monitor our `bookings` table in PostgreSQL and write the changes to a Kafka topic. The below configuration is built on the assumption that messages are sent as JSON without a schema. For general information on setting up a Debezium connector, please see [Aiven's documentation](https://aiven.io/docs/products/kafka/kafka-connect/howto/debezium-source-connector-pg#create-the-publication-in-postgresql)

```json
{
    "topic.prefix": "sql_topic",
    "name": "cdc-postgresql-SOURCE",
    "transforms": "flatten,router",
    "database.hostname": "<host>",
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.port": "<port>",
    "tombstones.on.delete": "false",
    "tasks.max": "1",
    "database.user": "avnadmin",
    "poll.interval.ms": "500",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "database.password": "<password>",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "database.dbname": "defaultdb",
    "plugin.name": "pgoutput",
    "slot.name": "cdc",
    "publication.name": "cdc",
    "publication.autocreate.mode": "all_tables",
    "database.sslmode": "require",
    "decimal.handling.mode": "precise",
    "table.include.list": "public.bookings",
    "snapshot.mode": "never",
    "hstore.handling.mode": "json",
    "database.trustServerCertificate": "true",
    "decimal.format": "BASE64",
    "include.schema.changes": "true",
    "key.converter.schemas.enable": "false",
    "output.data.format": "JSON",
    "output.key.format": "STRING",
    "schema.history.internal.consumer.security.protocol": "SSL",
    "schema.history.internal.consumer.ssl.key.password": "password",
    "schema.history.internal.consumer.ssl.keystore.location": "/run/aiven/keys/public.keystore.p12",
    "schema.history.internal.consumer.ssl.keystore.password": "password",
    "schema.history.internal.consumer.ssl.keystore.type": "PKCS12",
    "schema.history.internal.consumer.ssl.truststore.location": "/run/aiven/keys/public.truststore.jks",
    "schema.history.internal.consumer.ssl.truststore.password": "password",
    "schema.history.internal.kafka.bootstrap.servers": "URL.com:10934",
    "schema.history.internal.kafka.topic": "sql-testing-history",
    "schema.history.internal.producer.security.protocol": "SSL",
    "schema.history.internal.producer.ssl.key.password": "password",
    "schema.history.internal.producer.ssl.keystore.location": "/run/aiven/keys/public.keystore.p12",
    "schema.history.internal.producer.ssl.keystore.password": "password",
    "schema.history.internal.producer.ssl.keystore.type": "PKCS12",
    "schema.history.internal.producer.ssl.truststore.location": "/run/aiven/keys/public.truststore.jks",
    "schema.history.internal.producer.ssl.truststore.password": "password",
    "value.converter.schemas.enable": "false",
    "transforms.flatten.delimiter": ".",
    "transforms.flatten.type": "org.apache.kafka.connect.transforms.Flatten$Value",
    "transforms.router.regex": "sql_topic.public.(.*)",
    "transforms.router.replacement": "$1_changes",
    "transforms.router.type": "org.apache.kafka.connect.transforms.RegexRouter"
}
```

There are a number of things to mention here:
- In `table.include.list` we define the source table(s) (including the `schema_name`) to be monitored by Debezium,
- `publication.name` defines the name of the [PostgreSQL logical replication publication](https://www.postgresql.org/docs/current/logical-replication-publication.html) (`debezium` by default)
- `slot.name` defines the name of the  [PostgreSQL replication slot](https://aiven.io/docs/products/postgresql/howto/setup-logical-replication) (`debezium` by default)

> The naming is relevant here, because we will need it to resolve an error that appears because `avnadmin` is not a `superuser`. In Aiven's documentation you can [find out more](https://aiven.io/docs/products/kafka/kafka-connect/howto/debezium-source-connector-pg#solve-the-error-must-be-superuser-to-create-for-all-tables-publication) about this if you are curious. We will resolve this issue by creating a publication for all tables in PostgreSQL as shown below: 

a. Install the `aiven-extras` extension (this extension provides you with a number of operations that would otherwise be blocked for `avnadmin`): 
```sql
CREATE EXTENSION aiven_extras CASCADE;
```

b. Create a publication that has the same name as defined in your connector configuration under `publication.name`
```sql
SELECT *
FROM aiven_extras.pg_create_publication_for_all_tables(
   'cdc',
   'INSERT,UPDATE,DELETE'
);
```

- `"transforms": "flatten,router"`: We also make use of Debezium's transformation features: 
	- First, we flatten the original nested JSON format to align it with the `bookings_changes` schema. 
	- We also route the messages which Debezium will produce to a different target topic. We do this, because we need to ensure that the Kafka topic which receives the messages from Debezium has the same name as our ClickHouse table `bookings_changes` ([see here for more information](https://clickhouse.com/docs/integrations/kafka/clickhouse-kafka-connect-sink#target-tables)) 

#### ClickHouse Sink Connector
The setup of our ClickHouse Sink connector is straightforward now:
```json
{
    "hostname": "<host>",
    "name": "cdc-clickhouse-SINK",
    "port": "<port>",
    "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "database": "default",
    "username": "<user>",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "password": "<password>",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "ssl": "true",
    "topics": "bookings_changes",
    "exactlyOnce": "false",
    "schemas.enable": "false",
    "security.protocol": "SSL",
    "value.converter.schemas.enable": "false"
}
```

Good news! We're now ready to test the CDC workflow. 

## Inserts
```sql
INSERT INTO bookings (booking_id, status, is_deleted, is_canceled) VALUES 
('b11', 'New', 'False', 'False'),
('b12', 'New', 'False', 'False'),
('b13', 'New', 'False', 'False');
```

## Updates
```sql
UPDATE bookings SET status = 'In Progress', modified_at = (SELECT CURRENT_TIMESTAMP) WHERE status = 'Delayed' OR status = 'New';
```

```sql
UPDATE bookings SET status = 'Closed', modified_at = (SELECT CURRENT_TIMESTAMP) WHERE status = 'In Progress';
```

## Deletes
```sql
DELETE FROM bookings WHERE status = 'Closed';
```


#### Identical Entries
> *Note: we are using the FINAL operator in ClickHouse for query time deduplication. Otherwise we would have to run an OPTIMIZE TABLE <table_name> DEDUPLICATE statement before to make sure that all data parts are properly merged and no duplicates are in the table.*


```sql
-- Postgres 
SELECT * FROM bookings;

-- ClickHouse
SELECT * FROM bookings FINAL
```

#### Identical Row count

```sql
-- Postgres 
SELECT count(*) FROM bookings;

-- ClickHouse
SELECT count() FROM bookings FINAL
```
