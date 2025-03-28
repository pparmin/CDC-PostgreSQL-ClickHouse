CREATE TABLE bookings 
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
