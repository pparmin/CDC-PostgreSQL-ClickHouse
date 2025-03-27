CREATE TABLE bookings (
	id SERIAL PRIMARY KEY, 
	booking_id VARCHAR(50) NOT NULL,
	status TEXT NOT NULL,
	is_deleted boolean,
	is_canceled boolean,
	created_at TIMESTAMP DEFAULT timezone('UTC', CURRENT_TIMESTAMP),
	modified_at TIMESTAMP DEFAULT timezone('UTC', CURRENT_TIMESTAMP)
);
