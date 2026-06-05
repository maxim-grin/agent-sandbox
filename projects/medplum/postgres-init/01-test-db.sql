-- Create the separate test database used by Medplum's Jest suite.
-- loadTestConfig() hardcodes dbname='medplum_test'; this database must
-- exist and be owned by the medplum user before tests run.
CREATE DATABASE medplum_test;

-- Readonly user required by loadTestConfig()'s readonlyDatabase block.
CREATE USER medplum_test_readonly WITH PASSWORD 'medplum_test_readonly';

-- Let the medplum user own medplum_test (it runs migrations).
GRANT ALL PRIVILEGES ON DATABASE medplum_test TO medplum;

-- Connect to medplum_test to set up permissions in that DB.
\c medplum_test

GRANT CONNECT ON DATABASE medplum_test TO medplum_test_readonly;
GRANT USAGE ON SCHEMA public TO medplum_test_readonly;
-- Tables don't exist yet (migrations haven't run), so set DEFAULT PRIVILEGES
-- so that all tables created by future migrations are auto-granted to the
-- readonly user without a post-migration step.
ALTER DEFAULT PRIVILEGES FOR ROLE medplum IN SCHEMA public GRANT SELECT ON TABLES TO medplum_test_readonly;
