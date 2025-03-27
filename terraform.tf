terraform {
  required_providers {
    aiven = {
      source  = "aiven/aiven"
      version = ">=4.0.0, <5.0.0"
    }
  }
}

variable "aiven_api_token" {
  type        = string
  description = "API token to be used by provider"
}

variable "aiven_project_name" {
    description = "Aiven console project name"
    type        = string
}



provider "aiven" {
  api_token = var.aiven_api_token
}

# A single-node Postgres service
resource "aiven_pg" "pg" {
  project                 = var.aiven_project_name
  cloud_name              = "google-europe-west1"
  plan                    = "startup-8"
  service_name            = "philipp-cdc-poc-pg"
  maintenance_window_dow  = "monday"
  maintenance_window_time = "10:00:00"

}

resource "aiven_clickhouse" "clickhouse" {
  project                 = var.aiven_project_name
  cloud_name              = "google-europe-west1"
  plan                    = "startup-16"
  service_name            = "philipp-cdc-poc-ch"
  maintenance_window_dow  = "monday"
  maintenance_window_time = "10:00:00"
}

resource "aiven_kafka" "kafka" {
  project                 = var.aiven_project_name
  cloud_name              = "google-europe-west1"
  plan                    = "business-4"
  service_name            = "philipp-cdc-poc-kafka"
  maintenance_window_dow  = "monday"
  maintenance_window_time = "10:00:00"

  kafka_user_config {
    kafka_rest      = true
    kafka_connect   = true
    schema_registry = true
    kafka_version   = "3.8"

    public_access {
      kafka_rest    = true
      kafka_connect = true
      prometheus    = true
    }

    kafka {
      auto_create_topics_enable = "true"
    }
  }
}

resource "aiven_kafka_connect" "kafka-connect" {
  project      = var.aiven_project_name
  cloud_name   = "google-europe-west1"
  plan         = "startup-4"
  service_name = "philipp-cdc-poc-kafka-connect"

    kafka_connect_user_config {
    public_access {
      kafka_connect = true
    }
  }
}

resource "aiven_service_integration" "kafka-connect-integration" {
  project      = var.aiven_project_name
integration_type         = "kafka_connect"
source_service_name      = aiven_kafka.kafka.service_name
  destination_service_name = aiven_kafka_connect.kafka-connect.service_name
  # kafka_connect_user_config {
  #   kafka_connect {
  #     group_id = "connect"
  #     status_storage_topic = "__connect_status"
  #     offset_storage_topic = "__connect_offsets"
  #   }
  # }
}

resource "aiven_kafka_connector" "kafka-PG-SOURCE" { 
  project      = var.aiven_project_name
  service_name   = aiven_kafka_connect.kafka-connect.service_name
  connector_name = "cdc-postgresql-SOURCE"

  depends_on = [ 
    aiven_clickhouse.clickhouse, 
    aiven_kafka.kafka, aiven_pg.pg, 
    aiven_kafka_connect.kafka-connect, 
    aiven_service_integration.kafka-connect-integration 
  ]

  timeouts {
    create = "5m"
    default = "5m"
  }

  config = {
    "topic.prefix" = "sql_topic",
    "name" = "cdc-postgresql-SOURCE",
    "transforms" = "flatten,router",
    "database.hostname" = aiven_pg.pg.service_host,
    "connector.class" = "io.debezium.connector.postgresql.PostgresConnector",
    "database.port" = aiven_pg.pg.service_port,
    "tombstones.on.delete" = "false",
    "tasks.max" = "1",
    "database.user" = aiven_pg.pg.service_username,
    "poll.interval.ms" = "500",
    "key.converter" = "org.apache.kafka.connect.storage.StringConverter",
    "database.password" = aiven_pg.pg.service_password,
    "value.converter" = "org.apache.kafka.connect.json.JsonConverter",
    "database.dbname" = "defaultdb",
    "plugin.name" = "pgoutput",
    "slot.name" = "cdc",
    "publication.name" = "cdc",
    "publication.autocreate.mode" = "all_tables",
    "database.sslmode" = "require",
    "decimal.handling.mode" = "precise",
    "table.include.list" = "public.bookings",
    "snapshot.mode" = "never",
    "hstore.handling.mode" = "json",
    "database.trustServerCertificate" = "true",
    "decimal.format" = "BASE64",
    "include.schema.changes" = "true",
    "key.converter.schemas.enable" = "false",
    "output.data.format" = "JSON",
    "output.key.format" = "STRING",
    "schema.history.internal.consumer.security.protocol" = "SSL",
    "schema.history.internal.consumer.ssl.key.password" = "password",
    "schema.history.internal.consumer.ssl.keystore.location" = "/run/aiven/keys/public.keystore.p12",
    "schema.history.internal.consumer.ssl.keystore.password" = "password",
    "schema.history.internal.consumer.ssl.keystore.type" = "PKCS12",
    "schema.history.internal.consumer.ssl.truststore.location" = "/run/aiven/keys/public.truststore.jks",
    "schema.history.internal.consumer.ssl.truststore.password" = "password",
    "schema.history.internal.kafka.bootstrap.servers" = "URL.com:10934",
    "schema.history.internal.kafka.topic" = "sql-testing-history",
    "schema.history.internal.producer.security.protocol" = "SSL",
    "schema.history.internal.producer.ssl.key.password" = "password",
    "schema.history.internal.producer.ssl.keystore.location" = "/run/aiven/keys/public.keystore.p12",
    "schema.history.internal.producer.ssl.keystore.password" = "password",
    "schema.history.internal.producer.ssl.keystore.type" = "PKCS12",
    "schema.history.internal.producer.ssl.truststore.location" = "/run/aiven/keys/public.truststore.jks",
    "schema.history.internal.producer.ssl.truststore.password" = "password",
    "value.converter.schemas.enable" = "false",
    "transforms.flatten.delimiter" = ".",
    "transforms.flatten.type" = "org.apache.kafka.connect.transforms.Flatten$Value",
    "transforms.router.regex" = "sql_topic.public.(.*)",
    "transforms.router.replacement" = "$1_changes",
    "transforms.router.type" = "org.apache.kafka.connect.transforms.RegexRouter"
  }
}

resource "aiven_kafka_connector" "kafka-CH-SINK" { 
  project      = var.aiven_project_name
  service_name   = aiven_kafka_connect.kafka-connect.service_name
  connector_name = "cdc-clickhouse-SINK"

  depends_on = [ 
    aiven_clickhouse.clickhouse, 
    aiven_kafka.kafka, aiven_pg.pg, 
    aiven_kafka_connect.kafka-connect, 
    aiven_service_integration.kafka-connect-integration 
  ]

  timeouts {
    create = "5m"
    default = "5m"
  }

  config = {
    "hostname" = aiven_clickhouse.clickhouse.service_host,
    "name" = "cdc-clickhouse-SINK",
    "port" = aiven_clickhouse.clickhouse.service_port,
    "connector.class" = "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "database" = "default",
    "username" = aiven_clickhouse.clickhouse.service_username,
    "key.converter" = "org.apache.kafka.connect.storage.StringConverter",
    "password" = aiven_clickhouse.clickhouse.service_password,
    "value.converter" = "org.apache.kafka.connect.json.JsonConverter",
    "ssl" = "true",
    "topics" = "bookings_changes",
    "exactlyOnce" = "false",
    "schemas.enable" = "false",
    "security.protocol" = "SSL",
    "value.converter.schemas.enable" = "false"
  }
}


