-- ============================================================================
-- HYBRID MIGRATION: Keep Existing appointment_history
-- ============================================================================
-- This migration upgrades to the comprehensive schema while preserving
-- your unique appointment_history table and existing appointment structure.
--
-- Strategy: Add new comprehensive features alongside your existing tables
-- ============================================================================

-- ============================================================================
-- OPTION 1: Enhance Existing Appointments (Recommended)
-- ============================================================================

-- Add new columns to your existing appointments table
ALTER TABLE appointments
    ADD COLUMN IF NOT EXISTS workspace_id UUID REFERENCES workspaces(id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS contact_id UUID REFERENCES contacts(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS agent_id UUID REFERENCES voice_agents(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS title VARCHAR(255),
    ADD COLUMN IF NOT EXISTS description TEXT,
    ADD COLUMN IF NOT EXISTS appointment_type VARCHAR(100),
    ADD COLUMN IF NOT EXISTS scheduled_start TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS scheduled_end TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS duration_minutes INT,
    ADD COLUMN IF NOT EXISTS timezone VARCHAR(50) DEFAULT 'UTC',
    ADD COLUMN IF NOT EXISTS cancellation_reason VARCHAR(255),
    ADD COLUMN IF NOT EXISTS location_type VARCHAR(50) DEFAULT 'virtual',
    ADD COLUMN IF NOT EXISTS location_details TEXT,
    ADD COLUMN IF NOT EXISTS meeting_url TEXT,
    ADD COLUMN IF NOT EXISTS scheduled_by UUID REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS assigned_to UUID REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS reminder_sent BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS reminder_sent_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS calendar_provider VARCHAR(50),
    ADD COLUMN IF NOT EXISTS external_event_id VARCHAR(255),
    ADD COLUMN IF NOT EXISTS booking_call_id UUID REFERENCES calls(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE;

-- Populate new fields from existing data
UPDATE appointments
SET
    scheduled_start = (appointment_date::text || ' ' || appointment_time::text)::TIMESTAMP WITH TIME ZONE,
    scheduled_end = (appointment_date::text || ' ' || appointment_time::text)::TIMESTAMP WITH TIME ZONE + INTERVAL '1 hour',
    duration_minutes = 60,
    title = COALESCE(name, 'Appointment with ' || COALESCE(name, 'Guest')),
    location_details = address,
    scheduled_by = user_id,
    calendar_provider = CASE WHEN calendly_invitee_id IS NOT NULL THEN 'calendly' ELSE NULL END,
    external_event_id = calendly_invitee_id
WHERE scheduled_start IS NULL;

-- Link appointments to workspaces (based on tenant)
DO $$
BEGIN
    -- Try to link appointments to workspace via tenant
    UPDATE appointments a
    SET workspace_id = w.id
    FROM workspaces w
    WHERE w.tenant_id = a.tenant_id
      AND w.slug = 'default'
      AND a.workspace_id IS NULL;
END $$;

-- Add indexes for new columns
CREATE INDEX IF NOT EXISTS idx_appointments_workspace_id_new ON appointments(workspace_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_appointments_contact_id ON appointments(contact_id);
CREATE INDEX IF NOT EXISTS idx_appointments_agent_id ON appointments(agent_id);
CREATE INDEX IF NOT EXISTS idx_appointments_scheduled_start ON appointments(scheduled_start);
CREATE INDEX IF NOT EXISTS idx_appointments_booking_call_id ON appointments(booking_call_id);

-- ============================================================================
-- Keep appointment_history AS-IS (Your Unique Feature)
-- ============================================================================

-- Your appointment_history table is already perfect - no changes needed!
-- This gives you detailed change tracking that the standard schema doesn't have.

-- Add helpful indexes if not already present
CREATE INDEX IF NOT EXISTS idx_appointment_history_appointment_id ON appointment_history(appointment_id);
CREATE INDEX IF NOT EXISTS idx_appointment_history_change_date ON appointment_history(change_date);
CREATE INDEX IF NOT EXISTS idx_appointment_history_change_type ON appointment_history(change_type);

-- ============================================================================
-- OPTION 2: Create Appointment History Trigger (Optional Enhancement)
-- ============================================================================

-- This trigger automatically logs changes to appointment_history
-- when appointments are updated

CREATE OR REPLACE FUNCTION log_appointment_changes()
RETURNS TRIGGER AS $$
DECLARE
    old_data JSONB;
    new_data JSONB;
    change_type_val TEXT;
BEGIN
    -- Determine change type
    IF TG_OP = 'INSERT' THEN
        change_type_val := 'created';
        old_data := NULL;
        new_data := to_jsonb(NEW);
    ELSIF TG_OP = 'UPDATE' THEN
        change_type_val := 'updated';
        old_data := to_jsonb(OLD);
        new_data := to_jsonb(NEW);
    ELSIF TG_OP = 'DELETE' THEN
        change_type_val := 'deleted';
        old_data := to_jsonb(OLD);
        new_data := NULL;
    END IF;

    -- Insert into appointment_history
    INSERT INTO appointment_history (
        appointment_id,
        change_date,
        old_details,
        new_details,
        change_type
    ) VALUES (
        COALESCE(NEW.id, OLD.id),
        CURRENT_TIMESTAMP,
        old_data,
        new_data,
        change_type_val
    );

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Apply trigger (optional - comment out if you handle this in your app)
-- DROP TRIGGER IF EXISTS appointment_changes_trigger ON appointments;
-- CREATE TRIGGER appointment_changes_trigger
--     AFTER INSERT OR UPDATE OR DELETE ON appointments
--     FOR EACH ROW EXECUTE FUNCTION log_appointment_changes();

-- ============================================================================
-- OPTION 3: Create View for Appointment Details with History
-- ============================================================================

-- Helpful view that shows appointments with their full change history
CREATE OR REPLACE VIEW appointments_with_history AS
SELECT
    a.id,
    a.tenant_id,
    a.workspace_id,
    a.user_id,
    a.title,
    a.name,
    a.phone_number,
    a.address,
    a.scheduled_start,
    a.scheduled_end,
    a.appointment_date,
    a.appointment_time,
    a.status,
    a.calendly_invitee_id,
    a.created_at,
    a.updated_at,
    -- Aggregate history
    COALESCE(
        json_agg(
            json_build_object(
                'change_date', ah.change_date,
                'change_type', ah.change_type,
                'old_details', ah.old_details,
                'new_details', ah.new_details
            ) ORDER BY ah.change_date DESC
        ) FILTER (WHERE ah.id IS NOT NULL),
        '[]'::json
    ) as change_history,
    COUNT(ah.id) as total_changes
FROM appointments a
LEFT JOIN appointment_history ah ON a.id = ah.appointment_id
GROUP BY a.id, a.tenant_id, a.workspace_id, a.user_id, a.title, a.name,
         a.phone_number, a.address, a.scheduled_start, a.scheduled_end,
         a.appointment_date, a.appointment_time, a.status,
         a.calendly_invitee_id, a.created_at, a.updated_at;

-- ============================================================================
-- OPTION 4: Migrate appointment_history to audit_logs (Alternative)
-- ============================================================================

-- If you prefer to consolidate all change tracking into audit_logs:
-- (Comment this out if you want to keep appointment_history separate)

/*
INSERT INTO audit_logs (
    tenant_id,
    workspace_id,
    user_id,
    action,
    resource_type,
    resource_id,
    changes,
    metadata,
    created_at
)
SELECT
    a.tenant_id,
    a.workspace_id,
    a.user_id,
    'appointment.' || ah.change_type,
    'appointment',
    ah.appointment_id,
    jsonb_build_object(
        'old', ah.old_details,
        'new', ah.new_details
    ),
    jsonb_build_object(
        'source', 'appointment_history_migration'
    ),
    ah.change_date
FROM appointment_history ah
JOIN appointments a ON a.id = ah.appointment_id;

-- After confirming the migration, you could drop appointment_history:
-- DROP TABLE appointment_history;
*/

-- ============================================================================
-- Summary of Hybrid Approach
-- ============================================================================

COMMENT ON TABLE appointments IS 'Enhanced appointments table with backward compatibility for existing date/time fields';
COMMENT ON TABLE appointment_history IS 'Detailed change tracking - unique feature preserved from original schema';
COMMENT ON VIEW appointments_with_history IS 'Convenient view showing appointments with full change history';

-- ============================================================================
-- Migration Complete
-- ============================================================================

-- What you have now:
-- ✅ All new comprehensive schema features
-- ✅ Your existing appointments table (enhanced)
-- ✅ Your unique appointment_history table (preserved)
-- ✅ Backward compatibility with old appointment fields
-- ✅ New comprehensive appointment fields
-- ✅ Helpful view combining both

-- Recommendation:
-- 1. Keep both appointment_date/appointment_time AND scheduled_start/scheduled_end for now
-- 2. Update your app to use scheduled_start/scheduled_end going forward
-- 3. Maintain backward compatibility by syncing both fields
-- 4. Eventually deprecate old fields once fully migrated
