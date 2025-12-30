-- Supabase Database Schema for Voice AI Optimization
-- Run this in your Supabase SQL editor to set up the database

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- CALL LOGS TABLE
-- Stores all inbound/outbound call data
-- ============================================================================

CREATE TABLE IF NOT EXISTS call_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  call_id TEXT NOT NULL UNIQUE,
  phone_number TEXT NOT NULL,
  call_started_at TIMESTAMPTZ NOT NULL,
  call_ended_at TIMESTAMPTZ,
  duration_seconds INTEGER,
  outcome TEXT,  -- 'appointment_booked', 'transferred', 'voicemail', 'completed', etc.
  transcript JSONB,
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for fast lookups
CREATE INDEX IF NOT EXISTS idx_call_logs_phone ON call_logs(phone_number);
CREATE INDEX IF NOT EXISTS idx_call_logs_started ON call_logs(call_started_at DESC);
CREATE INDEX IF NOT EXISTS idx_call_logs_outcome ON call_logs(outcome);

-- ============================================================================
-- CONTACTS TABLE
-- Lightweight copy of CRM contacts for fast lookups
-- ============================================================================

CREATE TABLE IF NOT EXISTS contacts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  phone_number TEXT NOT NULL UNIQUE,
  name TEXT,
  email TEXT,
  company TEXT,
  ghl_contact_id TEXT,  -- Reference to GHL
  zep_session_id TEXT,  -- Reference to Zep
  tags TEXT[],
  custom_fields JSONB,
  last_call_at TIMESTAMPTZ,
  total_calls INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for fast lookups
CREATE INDEX IF NOT EXISTS idx_contacts_phone ON contacts(phone_number);
CREATE INDEX IF NOT EXISTS idx_contacts_last_call ON contacts(last_call_at DESC);
CREATE INDEX IF NOT EXISTS idx_contacts_ghl_id ON contacts(ghl_contact_id);

-- ============================================================================
-- APPOINTMENTS TABLE
-- Track all appointments booked through voice AI
-- ============================================================================

CREATE TABLE IF NOT EXISTS appointments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  contact_id UUID REFERENCES contacts(id) ON DELETE CASCADE,
  call_id UUID REFERENCES call_logs(id) ON DELETE SET NULL,
  ghl_appointment_id TEXT,  -- Reference to GHL
  scheduled_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'scheduled',  -- 'scheduled', 'completed', 'cancelled', 'no_show'
  reminder_sent BOOLEAN DEFAULT FALSE,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for queries
CREATE INDEX IF NOT EXISTS idx_appointments_contact ON appointments(contact_id);
CREATE INDEX IF NOT EXISTS idx_appointments_scheduled ON appointments(scheduled_at);
CREATE INDEX IF NOT EXISTS idx_appointments_status ON appointments(status);
CREATE INDEX IF NOT EXISTS idx_appointments_ghl_id ON appointments(ghl_appointment_id);

-- ============================================================================
-- DAILY METRICS TABLE
-- Pre-aggregated metrics for analytics dashboard
-- ============================================================================

CREATE TABLE IF NOT EXISTS daily_metrics (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  date DATE NOT NULL UNIQUE,
  total_calls INTEGER DEFAULT 0,
  appointments_booked INTEGER DEFAULT 0,
  transfers INTEGER DEFAULT 0,
  avg_call_duration NUMERIC(10, 2),
  conversion_rate NUMERIC(5, 2),
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for date queries
CREATE INDEX IF NOT EXISTS idx_daily_metrics_date ON daily_metrics(date DESC);

-- ============================================================================
-- CACHE ENTRIES TABLE
-- Alternative to Redis for fallback caching
-- ============================================================================

CREATE TABLE IF NOT EXISTS cache_entries (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for expiration cleanup
CREATE INDEX IF NOT EXISTS idx_cache_expires ON cache_entries(expires_at);

-- ============================================================================
-- FUNCTIONS AND TRIGGERS
-- ============================================================================

-- Function to auto-delete expired cache entries
CREATE OR REPLACE FUNCTION delete_expired_cache()
RETURNS void AS $$
BEGIN
  DELETE FROM cache_entries WHERE expires_at < NOW();
END;
$$ LANGUAGE plpgsql;

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers to auto-update updated_at
CREATE TRIGGER update_call_logs_updated_at
  BEFORE UPDATE ON call_logs
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_contacts_updated_at
  BEFORE UPDATE ON contacts
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_appointments_updated_at
  BEFORE UPDATE ON appointments
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_daily_metrics_updated_at
  BEFORE UPDATE ON daily_metrics
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- SCHEDULED CLEANUP (using pg_cron extension)
-- Note: pg_cron may not be available on all Supabase plans
-- Alternative: Run cleanup from your application periodically
-- ============================================================================

-- Uncomment if pg_cron is available:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
--
-- SELECT cron.schedule(
--   'delete-expired-cache',
--   '* * * * *',  -- Every minute
--   'SELECT delete_expired_cache();'
-- );

-- ============================================================================
-- ROW LEVEL SECURITY (RLS)
-- Optional: Enable if you need multi-tenant isolation
-- ============================================================================

-- Enable RLS on tables (uncomment if needed)
-- ALTER TABLE call_logs ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE contacts ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE appointments ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE daily_metrics ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE cache_entries ENABLE ROW LEVEL SECURITY;

-- Create policies as needed for your use case
-- Example: Allow service role full access
-- CREATE POLICY "Service role has full access" ON call_logs
--   FOR ALL
--   TO service_role
--   USING (true)
--   WITH CHECK (true);

-- ============================================================================
-- VIEWS FOR ANALYTICS
-- ============================================================================

-- View for recent call activity
CREATE OR REPLACE VIEW recent_calls AS
SELECT
  cl.call_id,
  cl.phone_number,
  c.name AS customer_name,
  cl.call_started_at,
  cl.call_ended_at,
  cl.duration_seconds,
  cl.outcome,
  c.total_calls
FROM call_logs cl
LEFT JOIN contacts c ON cl.phone_number = c.phone_number
ORDER BY cl.call_started_at DESC;

-- View for appointment summary
CREATE OR REPLACE VIEW appointment_summary AS
SELECT
  a.id,
  c.phone_number,
  c.name AS customer_name,
  a.scheduled_at,
  a.status,
  a.ghl_appointment_id,
  cl.call_id
FROM appointments a
JOIN contacts c ON a.contact_id = c.id
LEFT JOIN call_logs cl ON a.call_id = cl.id
ORDER BY a.scheduled_at DESC;

-- View for conversion metrics
CREATE OR REPLACE VIEW conversion_metrics AS
SELECT
  date,
  total_calls,
  appointments_booked,
  conversion_rate,
  avg_call_duration
FROM daily_metrics
ORDER BY date DESC;

-- ============================================================================
-- SAMPLE DATA (for testing)
-- Uncomment to insert test data
-- ============================================================================

-- INSERT INTO contacts (phone_number, name, tags, total_calls)
-- VALUES
--   ('5551234567', 'Test User', ARRAY['test', 'demo'], 0),
--   ('5559876543', 'Demo Customer', ARRAY['demo'], 0);

-- ============================================================================
-- CLEANUP COMMANDS (for development)
-- ============================================================================

-- Drop all tables (use with caution!)
-- DROP TABLE IF EXISTS appointments CASCADE;
-- DROP TABLE IF EXISTS call_logs CASCADE;
-- DROP TABLE IF EXISTS contacts CASCADE;
-- DROP TABLE IF EXISTS daily_metrics CASCADE;
-- DROP TABLE IF EXISTS cache_entries CASCADE;
-- DROP VIEW IF EXISTS recent_calls CASCADE;
-- DROP VIEW IF EXISTS appointment_summary CASCADE;
-- DROP VIEW IF EXISTS conversion_metrics CASCADE;
