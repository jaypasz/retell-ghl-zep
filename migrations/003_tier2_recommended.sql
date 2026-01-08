-- ============================================================================
-- TIER 2: HIGHLY RECOMMENDED FEATURES
-- ============================================================================
-- Production-ready features for voice AI platform
-- Includes: Call Analysis, Contact Interactions, Audit Logs, Enhanced Appointments
-- Excludes: Workflows (handled in FastAPI), Vector embeddings (using Zep)
-- ============================================================================

-- ============================================================================
-- CALL ANALYSIS
-- ============================================================================

CREATE TABLE IF NOT EXISTS call_analysis (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,

    -- AI Analysis Results
    sentiment VARCHAR(50),
    sentiment_score DECIMAL(3,2),
    intent VARCHAR(100),
    summary TEXT,
    key_phrases TEXT[],
    topics TEXT[],

    -- Quality Metrics
    call_quality_score DECIMAL(3,2),
    customer_satisfaction_score DECIMAL(3,2),
    agent_performance_score DECIMAL(3,2),

    -- Conversation Metrics
    customer_talk_time_seconds INT,
    agent_talk_time_seconds INT,
    silence_duration_seconds INT,
    interruptions_count INT,

    -- Outcomes
    call_successful BOOLEAN,
    action_items TEXT[],
    follow_up_required BOOLEAN,
    follow_up_date TIMESTAMP WITH TIME ZONE,

    -- Metadata
    analyzed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    analysis_model VARCHAR(100),
    metadata JSONB DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_call_analysis_call_id ON call_analysis(call_id);
CREATE INDEX IF NOT EXISTS idx_call_analysis_sentiment ON call_analysis(sentiment);
CREATE INDEX IF NOT EXISTS idx_call_analysis_successful ON call_analysis(call_successful);

-- ============================================================================
-- CALL TRANSCRIPT SEGMENTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS call_transcript_segments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
    transcript_id UUID REFERENCES call_transcripts(id) ON DELETE CASCADE,

    -- Segment Info
    speaker_role VARCHAR(50) NOT NULL,
    speaker_name VARCHAR(255),
    text TEXT NOT NULL,

    -- Timing
    start_time_seconds DECIMAL(10,3),
    end_time_seconds DECIMAL(10,3),

    -- Sentiment Analysis
    sentiment VARCHAR(50),
    confidence DECIMAL(3,2),

    -- Order
    sequence_number INT NOT NULL,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT valid_speaker_role CHECK (speaker_role IN ('agent', 'customer', 'system'))
);

CREATE INDEX IF NOT EXISTS idx_transcript_segments_call_id ON call_transcript_segments(call_id);
CREATE INDEX IF NOT EXISTS idx_transcript_segments_transcript_id ON call_transcript_segments(transcript_id);
CREATE INDEX IF NOT EXISTS idx_transcript_segments_sequence ON call_transcript_segments(call_id, sequence_number);

-- ============================================================================
-- CONTACT INTERACTIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS contact_interactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    contact_id UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,

    -- Interaction Type
    interaction_type VARCHAR(50) NOT NULL,
    direction VARCHAR(20),

    -- Related Records
    call_id UUID REFERENCES calls(id) ON DELETE SET NULL,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,

    -- Content
    subject VARCHAR(500),
    body TEXT,

    -- Outcome
    outcome VARCHAR(100),
    outcome_details TEXT,

    -- Scheduling
    scheduled_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT valid_interaction_type CHECK (
        interaction_type IN ('call', 'email', 'sms', 'note', 'task', 'meeting', 'other')
    ),
    CONSTRAINT valid_direction CHECK (direction IN ('inbound', 'outbound', NULL))
);

CREATE INDEX IF NOT EXISTS idx_contact_interactions_workspace ON contact_interactions(workspace_id);
CREATE INDEX IF NOT EXISTS idx_contact_interactions_contact ON contact_interactions(contact_id);
CREATE INDEX IF NOT EXISTS idx_contact_interactions_call ON contact_interactions(call_id);
CREATE INDEX IF NOT EXISTS idx_contact_interactions_type ON contact_interactions(interaction_type);
CREATE INDEX IF NOT EXISTS idx_contact_interactions_scheduled ON contact_interactions(scheduled_at)
    WHERE scheduled_at IS NOT NULL;

-- ============================================================================
-- ENHANCED APPOINTMENTS
-- ============================================================================

-- Upgrade existing appointments table
ALTER TABLE appointments
    ADD COLUMN IF NOT EXISTS workspace_id UUID REFERENCES workspaces(id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS agent_id UUID REFERENCES voice_agents(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS call_id UUID REFERENCES calls(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS contact_id UUID REFERENCES contacts(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS title VARCHAR(500),
    ADD COLUMN IF NOT EXISTS description TEXT,
    ADD COLUMN IF NOT EXISTS location_type VARCHAR(50) DEFAULT 'phone',
    ADD COLUMN IF NOT EXISTS location_details JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS duration_minutes INT DEFAULT 30,
    ADD COLUMN IF NOT EXISTS appointment_status VARCHAR(50) DEFAULT 'scheduled',
    ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS cancellation_reason TEXT,
    ADD COLUMN IF NOT EXISTS reminder_sent BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS reminder_sent_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS notes TEXT,
    ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE;

-- Add constraints
ALTER TABLE appointments
    ADD CONSTRAINT IF NOT EXISTS valid_location_type
    CHECK (location_type IN ('phone', 'video', 'in_person', 'other'));

ALTER TABLE appointments
    ADD CONSTRAINT IF NOT EXISTS valid_appointment_status
    CHECK (appointment_status IN ('scheduled', 'confirmed', 'completed', 'cancelled', 'no_show'));

-- Update existing appointments to link to workspace
UPDATE appointments a
SET workspace_id = (
    SELECT w.id
    FROM workspaces w
    WHERE w.tenant_id = a.tenant_id AND w.slug = 'default'
    LIMIT 1
)
WHERE workspace_id IS NULL;

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_appointments_workspace ON appointments(workspace_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_appointments_agent ON appointments(agent_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_appointments_contact ON appointments(contact_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_appointments_call ON appointments(call_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_appointments_status ON appointments(appointment_status);
CREATE INDEX IF NOT EXISTS idx_appointments_start_time ON appointments(start_time);

-- ============================================================================
-- AUDIT LOGS (Replaces appointment_history)
-- ============================================================================

CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID REFERENCES workspaces(id) ON DELETE CASCADE,
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,

    -- Action Details
    action VARCHAR(100) NOT NULL,
    entity_type VARCHAR(100) NOT NULL,
    entity_id UUID NOT NULL,

    -- User who performed the action
    performed_by UUID REFERENCES users(id) ON DELETE SET NULL,
    performed_by_name VARCHAR(255),
    performed_by_email VARCHAR(255),

    -- Changes
    old_values JSONB,
    new_values JSONB,
    changes JSONB,

    -- Request Context
    ip_address INET,
    user_agent TEXT,
    request_id VARCHAR(255),

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    -- Index for entity lookups
    CONSTRAINT audit_logs_entity_composite UNIQUE (entity_type, entity_id, created_at)
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_workspace ON audit_logs(workspace_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_tenant ON audit_logs(tenant_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_audit_logs_performed_by ON audit_logs(performed_by);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at DESC);

-- ============================================================================
-- MIGRATE APPOINTMENT_HISTORY TO AUDIT_LOGS
-- ============================================================================

-- Migrate existing appointment_history records to audit_logs
INSERT INTO audit_logs (
    workspace_id,
    tenant_id,
    action,
    entity_type,
    entity_id,
    performed_by,
    performed_by_name,
    old_values,
    new_values,
    changes,
    metadata,
    created_at
)
SELECT
    w.id as workspace_id,
    ah.tenant_id,
    ah.change_type as action,
    'appointment' as entity_type,
    ah.appointment_id as entity_id,
    ah.changed_by as performed_by,
    u.name as performed_by_name,
    jsonb_build_object(
        'start_time', ah.old_start_time,
        'end_time', ah.old_end_time,
        'status', ah.old_status
    ) as old_values,
    jsonb_build_object(
        'start_time', ah.new_start_time,
        'end_time', ah.new_end_time,
        'status', ah.new_status
    ) as new_values,
    jsonb_build_object(
        'reason', ah.reason,
        'details', ah.details
    ) as changes,
    COALESCE(ah.metadata, '{}'::jsonb) as metadata,
    ah.changed_at as created_at
FROM appointment_history ah
LEFT JOIN workspaces w ON w.tenant_id = ah.tenant_id AND w.slug = 'default'
LEFT JOIN users u ON u.id = ah.changed_by
WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'appointment_history')
ON CONFLICT (entity_type, entity_id, created_at) DO NOTHING;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

DROP TRIGGER IF EXISTS update_appointments_updated_at ON appointments;
CREATE TRIGGER update_appointments_updated_at BEFORE UPDATE ON appointments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_contact_interactions_updated_at ON contact_interactions;
CREATE TRIGGER update_contact_interactions_updated_at BEFORE UPDATE ON contact_interactions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- AUDIT LOG TRIGGER FUNCTION
-- ============================================================================

CREATE OR REPLACE FUNCTION log_appointment_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_old_values JSONB;
    v_new_values JSONB;
    v_changes JSONB;
    v_action VARCHAR(100);
BEGIN
    -- Determine action type
    IF TG_OP = 'INSERT' THEN
        v_action := 'appointment_created';
        v_old_values := NULL;
        v_new_values := to_jsonb(NEW);
        v_changes := v_new_values;
    ELSIF TG_OP = 'UPDATE' THEN
        -- Determine specific update action
        IF OLD.appointment_status != NEW.appointment_status THEN
            v_action := 'appointment_status_changed';
        ELSIF OLD.start_time != NEW.start_time THEN
            v_action := 'appointment_rescheduled';
        ELSE
            v_action := 'appointment_updated';
        END IF;

        v_old_values := to_jsonb(OLD);
        v_new_values := to_jsonb(NEW);

        -- Calculate changes
        v_changes := jsonb_build_object(
            'start_time_changed', OLD.start_time != NEW.start_time,
            'status_changed', OLD.appointment_status != NEW.appointment_status,
            'old_start_time', OLD.start_time,
            'new_start_time', NEW.start_time,
            'old_status', OLD.appointment_status,
            'new_status', NEW.appointment_status
        );
    ELSIF TG_OP = 'DELETE' THEN
        v_action := 'appointment_deleted';
        v_old_values := to_jsonb(OLD);
        v_new_values := NULL;
        v_changes := v_old_values;
    END IF;

    -- Insert audit log
    INSERT INTO audit_logs (
        workspace_id,
        tenant_id,
        action,
        entity_type,
        entity_id,
        old_values,
        new_values,
        changes
    ) VALUES (
        COALESCE(NEW.workspace_id, OLD.workspace_id),
        COALESCE(NEW.tenant_id, OLD.tenant_id),
        v_action,
        'appointment',
        COALESCE(NEW.id, OLD.id),
        v_old_values,
        v_new_values,
        v_changes
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for appointment audit logging
DROP TRIGGER IF EXISTS appointments_audit_trigger ON appointments;
CREATE TRIGGER appointments_audit_trigger
    AFTER INSERT OR UPDATE OR DELETE ON appointments
    FOR EACH ROW EXECUTE FUNCTION log_appointment_changes();

-- ============================================================================
-- VIEWS FOR ANALYTICS
-- ============================================================================

-- Call analytics summary view
CREATE OR REPLACE VIEW v_call_analytics AS
SELECT
    c.id as call_id,
    c.agent_id,
    c.workspace_id,
    c.contact_id,
    c.caller_phone,
    c.direction,
    c.call_status,
    c.started_at,
    c.ended_at,
    c.duration_seconds,
    ca.sentiment,
    ca.sentiment_score,
    ca.intent,
    ca.call_quality_score,
    ca.customer_satisfaction_score,
    ca.call_successful,
    ca.follow_up_required,
    ct.full_transcript
FROM calls c
LEFT JOIN call_analysis ca ON ca.call_id = c.id
LEFT JOIN call_transcripts ct ON ct.call_id = c.id;

-- Contact interaction timeline view
CREATE OR REPLACE VIEW v_contact_timeline AS
SELECT
    ci.id,
    ci.workspace_id,
    ci.contact_id,
    ci.interaction_type,
    ci.direction,
    ci.subject,
    ci.outcome,
    ci.created_at,
    c.full_name as contact_name,
    c.phone as contact_phone,
    c.email as contact_email,
    u.name as user_name,
    calls.caller_phone,
    calls.duration_seconds
FROM contact_interactions ci
LEFT JOIN contacts c ON c.id = ci.contact_id
LEFT JOIN users u ON u.id = ci.user_id
LEFT JOIN calls ON calls.id = ci.call_id
ORDER BY ci.created_at DESC;

-- Appointment audit trail view
CREATE OR REPLACE VIEW v_appointment_audit_trail AS
SELECT
    al.id,
    al.entity_id as appointment_id,
    al.action,
    al.performed_by,
    al.performed_by_name,
    al.old_values,
    al.new_values,
    al.changes,
    al.created_at,
    a.title as appointment_title,
    a.start_time,
    a.appointment_status,
    c.full_name as contact_name
FROM audit_logs al
LEFT JOIN appointments a ON a.id = al.entity_id
LEFT JOIN contacts c ON c.id = a.contact_id
WHERE al.entity_type = 'appointment'
ORDER BY al.created_at DESC;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE call_analysis IS 'AI-powered analysis of call sentiment, quality, and outcomes';
COMMENT ON TABLE call_transcript_segments IS 'Turn-by-turn transcript segments with speaker attribution';
COMMENT ON TABLE contact_interactions IS 'All contact touchpoints (calls, emails, notes, tasks)';
COMMENT ON TABLE audit_logs IS 'System-wide audit trail for compliance and debugging';
COMMENT ON VIEW v_call_analytics IS 'Combined view of calls with analysis metrics';
COMMENT ON VIEW v_contact_timeline IS 'Chronological view of all contact interactions';
COMMENT ON VIEW v_appointment_audit_trail IS 'Complete audit history of appointment changes';

-- ============================================================================
COMMENT ON SCHEMA public IS 'Tier 2: Production-Ready Voice AI Platform (GHL-Complementary)';
