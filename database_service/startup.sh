#!/bin/bash

# Minimal PostgreSQL startup script with full paths
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

# Check if PostgreSQL is already running on the specified port
if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}!"
    echo "Database: ${DB_NAME}"
    echo "User: ${DB_USER}"
    echo "Port: ${DB_PORT}"
    echo ""
    echo "To connect to the database, use:"
    echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"

    # Check if connection info file exists
    if [ -f "db_connection.txt" ]; then
        echo "Or use: $(cat db_connection.txt)"
    fi

    echo ""
    echo "Script stopped - server already running."
    exit 0
fi

# Also check if there's a PostgreSQL process running (in case pg_isready fails)
if pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
    echo "Found existing PostgreSQL process on port ${DB_PORT}"
    echo "Attempting to verify connection..."

    # Try to connect and verify the database exists
    if sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} -c '\q' 2>/dev/null; then
        echo "Database ${DB_NAME} is accessible."
        echo "Script stopped - server already running."
        exit 0
    fi
fi

# Initialize PostgreSQL data directory if it doesn't exist
if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
    echo "Initializing PostgreSQL..."
    sudo -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/data
fi

# Start PostgreSQL server in background
echo "Starting PostgreSQL server..."
sudo -u postgres ${PG_BIN}/postgres -D /var/lib/postgresql/data -p ${DB_PORT} &

# Wait for PostgreSQL to start
echo "Waiting for PostgreSQL to start..."
sleep 5

# Check if PostgreSQL is running
for i in {1..15}; do
    if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
        echo "PostgreSQL is ready!"
        break
    fi
    echo "Waiting... ($i/15)"
    sleep 2
done

# Create database and user
echo "Setting up database and user..."
sudo -u postgres ${PG_BIN}/createdb -p ${DB_PORT} ${DB_NAME} 2>/dev/null || echo "Database might already exist"

# Set up user and permissions with proper schema ownership
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d postgres << EOF
-- Create user if doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

-- Grant database-level permissions
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the specific database for schema-level permissions
\c ${DB_NAME}

-- For PostgreSQL 15+, we need to handle public schema permissions differently
-- First, grant usage on public schema
GRANT USAGE ON SCHEMA public TO ${DB_USER};

-- Grant CREATE permission on public schema
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Make the user owner of all future objects they create in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

-- If you want the user to be able to create objects without restrictions,
-- you can make them the owner of the public schema (optional but effective)
-- ALTER SCHEMA public OWNER TO ${DB_USER};

-- Alternative: Grant all privileges on schema public to the user
GRANT ALL ON SCHEMA public TO ${DB_USER};

-- Ensure the user can work with any existing objects
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Additionally, connect to the specific database to ensure permissions
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} << EOF
-- Double-check permissions are set correctly in the target database
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Show current permissions for debugging
\dn+ public
EOF

# Save connection command to a file
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

# -----------------------------------------------------------------------------
# Domain schema bootstrapping / migrations (idempotent, no standalone .sql files)
# -----------------------------------------------------------------------------
# Contract:
# - Inputs: DB_NAME, DB_USER, DB_PASSWORD, DB_PORT
# - Side effects: creates/updates tables, indexes, functions in public schema
# - Errors: any SQL error stops the script (set -e behavior)
# - Invariants:
#   * Single exam attempt is enforced by UNIQUE(exam_id, user_id) on exam_attempts
#   * Timed exams use duration_seconds default 1200 (20 minutes)
#   * Pass threshold uses pass_percent default 80.00 (80%)
# -----------------------------------------------------------------------------
echo "Bootstrapping domain schema (users/courses/modules/questions/exams/attempts/responses/progress)..."

PSQL_CONN="postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}"

# Helper to run one SQL statement at a time (repo rule), with clear logging.
run_sql () {
    local stmt="$1"
    echo "  -> SQL: ${stmt}"
    psql "${PSQL_CONN}" -v ON_ERROR_STOP=1 -c "${stmt}"
}

# Migration tracker
run_sql "CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());"

# UUID generator
run_sql "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# Core domain tables
run_sql "CREATE TABLE IF NOT EXISTS users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text UNIQUE NOT NULL, full_name text, is_admin boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"
run_sql "CREATE TABLE IF NOT EXISTS courses (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), slug text UNIQUE NOT NULL, title text NOT NULL, description text, is_published boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"
run_sql "CREATE TABLE IF NOT EXISTS modules (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), course_id uuid NOT NULL REFERENCES courses(id) ON DELETE CASCADE, slug text NOT NULL, title text NOT NULL, description text, sort_order int NOT NULL DEFAULT 0, is_published boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(course_id, slug));"

run_sql "CREATE TABLE IF NOT EXISTS questions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), module_id uuid NOT NULL REFERENCES modules(id) ON DELETE CASCADE, question_type text NOT NULL, prompt text NOT NULL, explanation text, difficulty int NOT NULL DEFAULT 1, is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"
run_sql "CREATE TABLE IF NOT EXISTS question_choices (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), question_id uuid NOT NULL REFERENCES questions(id) ON DELETE CASCADE, choice_text text NOT NULL, is_correct boolean NOT NULL DEFAULT false, sort_order int NOT NULL DEFAULT 0, UNIQUE(question_id, sort_order));"

# Exams: configuration per module (20 minutes, 80% pass)
run_sql "CREATE TABLE IF NOT EXISTS exams (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), module_id uuid NOT NULL UNIQUE REFERENCES modules(id) ON DELETE CASCADE, duration_seconds int NOT NULL DEFAULT 1200, pass_percent numeric(5,2) NOT NULL DEFAULT 80.00, total_questions int, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), CHECK (duration_seconds > 0), CHECK (pass_percent >= 0 AND pass_percent <= 100));"

# Attempts: single attempt constraint enforced by UNIQUE(exam_id, user_id)
run_sql "CREATE TABLE IF NOT EXISTS exam_attempts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), exam_id uuid NOT NULL REFERENCES exams(id) ON DELETE CASCADE, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, started_at timestamptz NOT NULL DEFAULT now(), submitted_at timestamptz, expires_at timestamptz NOT NULL, status text NOT NULL DEFAULT 'in_progress', total_questions int NOT NULL DEFAULT 0, correct_count int NOT NULL DEFAULT 0, score_percent numeric(5,2) NOT NULL DEFAULT 0.00, passed boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), CHECK (status IN ('in_progress','submitted','expired')), CHECK (total_questions >= 0), CHECK (correct_count >= 0), CHECK (score_percent >= 0 AND score_percent <= 100), UNIQUE (exam_id, user_id));"

run_sql "CREATE TABLE IF NOT EXISTS exam_questions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), exam_id uuid NOT NULL REFERENCES exams(id) ON DELETE CASCADE, question_id uuid NOT NULL REFERENCES questions(id) ON DELETE RESTRICT, sort_order int NOT NULL DEFAULT 0, UNIQUE(exam_id, question_id), UNIQUE(exam_id, sort_order));"

run_sql "CREATE TABLE IF NOT EXISTS exam_responses (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), attempt_id uuid NOT NULL REFERENCES exam_attempts(id) ON DELETE CASCADE, question_id uuid NOT NULL REFERENCES questions(id) ON DELETE RESTRICT, selected_choice_id uuid REFERENCES question_choices(id) ON DELETE SET NULL, free_text_response text, is_correct boolean, answered_at timestamptz NOT NULL DEFAULT now(), UNIQUE(attempt_id, question_id));"

# Progress tracking (per user per module)
run_sql "CREATE TABLE IF NOT EXISTS module_progress (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, module_id uuid NOT NULL REFERENCES modules(id) ON DELETE CASCADE, started_at timestamptz, completed_at timestamptz, last_activity_at timestamptz NOT NULL DEFAULT now(), exam_attempt_id uuid UNIQUE REFERENCES exam_attempts(id) ON DELETE SET NULL, exam_passed boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(user_id, module_id));"

# Indexes
run_sql "CREATE INDEX IF NOT EXISTS idx_modules_course_id ON modules(course_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_questions_module_id ON questions(module_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_exam_attempts_user_id ON exam_attempts(user_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_exam_attempts_exam_id ON exam_attempts(exam_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_exam_attempts_status_expires_at ON exam_attempts(status, expires_at);"
run_sql "CREATE INDEX IF NOT EXISTS idx_exam_responses_attempt_id ON exam_responses(attempt_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_module_progress_user_id ON module_progress(user_id);"

# updated_at management
run_sql "CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS \\$\\$ BEGIN NEW.updated_at = now(); RETURN NEW; END; \\$\\$ LANGUAGE plpgsql;"
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_users_updated_at') THEN CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \\$\\$;"
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_courses_updated_at') THEN CREATE TRIGGER trg_courses_updated_at BEFORE UPDATE ON courses FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \\$\\$;"
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_modules_updated_at') THEN CREATE TRIGGER trg_modules_updated_at BEFORE UPDATE ON modules FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \\$\\$;"
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_questions_updated_at') THEN CREATE TRIGGER trg_questions_updated_at BEFORE UPDATE ON questions FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \\$\\$;"
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_exams_updated_at') THEN CREATE TRIGGER trg_exams_updated_at BEFORE UPDATE ON exams FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \\$\\$;"
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_exam_attempts_updated_at') THEN CREATE TRIGGER trg_exam_attempts_updated_at BEFORE UPDATE ON exam_attempts FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \\$\\$;"
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_module_progress_updated_at') THEN CREATE TRIGGER trg_module_progress_updated_at BEFORE UPDATE ON module_progress FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \\$\\$;"

# expires_at initialization: started_at + exams.duration_seconds (default 1200)
run_sql "CREATE OR REPLACE FUNCTION init_exam_attempt_expires_at() RETURNS trigger AS \\$\\$ DECLARE dur_seconds int; BEGIN IF NEW.expires_at IS NULL THEN SELECT duration_seconds INTO dur_seconds FROM exams WHERE id = NEW.exam_id; IF dur_seconds IS NULL THEN dur_seconds := 1200; END IF; NEW.expires_at := NEW.started_at + make_interval(secs => dur_seconds); END IF; RETURN NEW; END; \\$\\$ LANGUAGE plpgsql;"
run_sql "DO \\$\\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_exam_attempts_init_expires') THEN CREATE TRIGGER trg_exam_attempts_init_expires BEFORE INSERT ON exam_attempts FOR EACH ROW EXECUTE FUNCTION init_exam_attempt_expires_at(); END IF; END \\$\\$;"

# Stable DB-side flows for starting/submitting attempts (single attempt + expiry + scoring)
run_sql "CREATE OR REPLACE FUNCTION start_exam_attempt(p_exam_id uuid, p_user_id uuid) RETURNS exam_attempts AS \\$\\$ DECLARE new_attempt exam_attempts%ROWTYPE; now_ts timestamptz; dur_seconds int; BEGIN now_ts := now(); SELECT duration_seconds INTO dur_seconds FROM exams WHERE id = p_exam_id; IF dur_seconds IS NULL THEN dur_seconds := 1200; END IF; INSERT INTO exam_attempts (exam_id, user_id, started_at, expires_at, status) VALUES (p_exam_id, p_user_id, now_ts, now_ts + make_interval(secs => dur_seconds), 'in_progress') RETURNING * INTO new_attempt; RETURN new_attempt; EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'attempt_already_exists'; END; \\$\\$ LANGUAGE plpgsql;"

run_sql "CREATE OR REPLACE FUNCTION submit_exam_attempt(p_attempt_id uuid) RETURNS exam_attempts AS \\$\\$ DECLARE attempt_row exam_attempts%ROWTYPE; now_ts timestamptz; BEGIN now_ts := now(); SELECT * INTO attempt_row FROM exam_attempts WHERE id = p_attempt_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'attempt_not_found'; END IF; IF attempt_row.status <> 'in_progress' THEN RAISE EXCEPTION 'attempt_not_in_progress'; END IF; UPDATE exam_attempts SET (total_questions, correct_count, score_percent, passed) = (s.total_questions, s.correct_count, s.score_percent, s.passed) FROM ( SELECT tq.total_questions, cq.correct_count, sp.score_percent, (sp.score_percent >= pp.pass_percent) AS passed FROM (SELECT * FROM exam_attempts WHERE id = p_attempt_id) a CROSS JOIN LATERAL (SELECT COUNT(*)::int AS total_questions FROM exam_questions WHERE exam_id = a.exam_id) tq CROSS JOIN LATERAL (SELECT COUNT(*)::int AS correct_count FROM exam_responses WHERE attempt_id = a.id AND is_correct IS TRUE) cq CROSS JOIN LATERAL (SELECT COALESCE((SELECT pass_percent FROM exams WHERE id = a.exam_id), 80.00)::numeric(5,2) AS pass_percent) pp CROSS JOIN LATERAL (SELECT CASE WHEN tq.total_questions = 0 THEN 0.00::numeric(5,2) ELSE ROUND((cq.correct_count::numeric / tq.total_questions::numeric) * 100.0, 2)::numeric(5,2) END AS score_percent) sp ) AS s WHERE exam_attempts.id = p_attempt_id; SELECT * INTO attempt_row FROM exam_attempts WHERE id = p_attempt_id; IF now_ts > attempt_row.expires_at THEN UPDATE exam_attempts SET status='expired', submitted_at=COALESCE(submitted_at, now_ts) WHERE id=p_attempt_id RETURNING * INTO attempt_row; RETURN attempt_row; END IF; UPDATE exam_attempts SET submitted_at=now_ts, status='submitted' WHERE id=p_attempt_id RETURNING * INTO attempt_row; RETURN attempt_row; END; \\$\\$ LANGUAGE plpgsql;"

# Mark migration applied (informational)
run_sql "INSERT INTO schema_migrations(version) VALUES ('001_init') ON CONFLICT (version) DO NOTHING;"

echo "Domain schema bootstrap complete."

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""

echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"

echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"
