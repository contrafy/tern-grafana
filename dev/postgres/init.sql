-- Seed for the PostgreSQL datasource (uid postgres) behind dashboard tern-sql. Runs once, when the
-- container's database is created (docker-entrypoint-initdb.d).

CREATE TABLE services (
	name text PRIMARY KEY,
	team text NOT NULL,
	region text NOT NULL,
	replicas integer NOT NULL,
	error_rate double precision NOT NULL
);

INSERT INTO services (name, team, region, replicas, error_rate) VALUES
	('frontend', 'web', 'eu', 3, 0.012),
	('checkout', 'payments', 'eu', 2, 0.034),
	('payments', 'payments', 'us', 4, 0.051),
	('search', 'web', 'us', 2, 0.007);

-- Per-minute load of every service over the last day, computed at query time so every range in the
-- past 24 hours has rows whenever the stack was started. Deterministic per minute.
CREATE VIEW service_load AS
SELECT
	t AS time,
	s.name AS service,
	round((40 + 10 * s.replicas + 15 * sin(extract(epoch FROM t) / 900 + length(s.name)))::numeric, 2)::float8 AS rps
FROM services s,
	generate_series(date_trunc('minute', now()) - interval '1 day', date_trunc('minute', now()), interval '1 minute') AS t;
