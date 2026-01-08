-- ============================================================================
-- TIER 4: ADVANCED FEATURES
-- ============================================================================
-- Webhooks and analytics for voice AI platform
-- Includes: Webhooks, Webhook Deliveries, Analytics Metrics
-- Excludes: Workflows (handled in FastAPI), Workflow Integrations
-- ============================================================================

-- ============================================================================
-- WEBHOOKS
-- ============================================================================

CREATE TABLE IF NOT EXISTS webhooks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    -- Webhook Info
    name VARCHAR(255) NOT NULL,
    description TEXT,
    url TEXT NOT NULL,

    -- Events to listen for
    events TEXT[] NOT NULL DEFAULT '{}',

    -- Security
    secret_key VARCHAR(255) NOT NULL,
    signature_header VARCHAR(100) DEFAULT 'X-Webhook-Signature',

    -- Configuration
    http_method VARCHAR(10) DEFAULT 'POST',
    headers JSONB DEFAULT '{}',
    timeout_seconds INT DEFAULT 30,
    retry_count INT DEFAULT 3,

    -- Filters
    filters JSONB DEFAULT '{}',

    -- Status
    is_active BOOLEAN DEFAULT true,

    -- Statistics
    total_deliveries INT DEFAULT 0,
    successful_deliveries INT DEFAULT 0,
    failed_deliveries INT DEFAULT 0,
    last_triggered_at TIMESTAMP WITH TIME ZONE,

    -- Metadata
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,

    CONSTRAINT valid_http_method CHECK (http_method IN ('POST', 'PUT', 'PATCH')),
    CONSTRAINT valid_retry_count CHECK (retry_count >= 0 AND retry_count <= 10)
);

CREATE INDEX IF NOT EXISTS idx_webhooks_workspace ON webhooks(workspace_id) WHERE deleted_at IS NULL AND is_active = true;
CREATE INDEX IF NOT EXISTS idx_webhooks_events ON webhooks USING gin(events);

-- Common webhook events:
-- 'call.started', 'call.ended', 'call.analyzed', 'call.failed',
-- 'appointment.created', 'appointment.updated', 'appointment.cancelled',
-- 'contact.created', 'contact.updated', 'transaction.created', 'transaction.won'

-- ============================================================================
-- WEBHOOK DELIVERIES
-- ============================================================================

CREATE TABLE IF NOT EXISTS webhook_deliveries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    webhook_id UUID NOT NULL REFERENCES webhooks(id) ON DELETE CASCADE,

    -- Event Info
    event_type VARCHAR(100) NOT NULL,
    event_id UUID,

    -- Request
    request_url TEXT NOT NULL,
    request_method VARCHAR(10) NOT NULL,
    request_headers JSONB,
    request_body JSONB,

    -- Response
    response_status_code INT,
    response_headers JSONB,
    response_body TEXT,

    -- Timing
    duration_ms INT,

    -- Status
    status VARCHAR(50) NOT NULL,
    error_message TEXT,

    -- Retry Info
    attempt_number INT DEFAULT 1,
    max_attempts INT DEFAULT 3,
    next_retry_at TIMESTAMP WITH TIME ZONE,

    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    delivered_at TIMESTAMP WITH TIME ZONE,

    CONSTRAINT valid_delivery_status CHECK (
        status IN ('pending', 'delivered', 'failed', 'retrying', 'cancelled')
    )
);

CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_webhook ON webhook_deliveries(webhook_id);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_status ON webhook_deliveries(status);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_event ON webhook_deliveries(event_type, event_id);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_next_retry ON webhook_deliveries(next_retry_at)
    WHERE next_retry_at IS NOT NULL AND status = 'retrying';
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_created ON webhook_deliveries(created_at DESC);

-- ============================================================================
-- ANALYTICS: AGENT DAILY METRICS
-- ============================================================================

CREATE TABLE IF NOT EXISTS agent_daily_metrics (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL REFERENCES voice_agents(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    metric_date DATE NOT NULL,

    -- Call Volume
    total_calls INT DEFAULT 0,
    inbound_calls INT DEFAULT 0,
    outbound_calls INT DEFAULT 0,

    -- Call Outcomes
    completed_calls INT DEFAULT 0,
    failed_calls INT DEFAULT 0,
    missed_calls INT DEFAULT 0,

    -- Duration Metrics
    total_duration_seconds INT DEFAULT 0,
    avg_duration_seconds INT DEFAULT 0,
    max_duration_seconds INT DEFAULT 0,

    -- Quality Metrics
    avg_quality_score DECIMAL(3,2),
    avg_sentiment_score DECIMAL(3,2),
    positive_sentiment_count INT DEFAULT 0,
    negative_sentiment_count INT DEFAULT 0,
    neutral_sentiment_count INT DEFAULT 0,

    -- Success Metrics
    successful_outcomes INT DEFAULT 0,
    appointments_booked INT DEFAULT 0,
    transfers_count INT DEFAULT 0,

    -- Customer Metrics
    unique_callers INT DEFAULT 0,
    repeat_callers INT DEFAULT 0,
    new_contacts_created INT DEFAULT 0,

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT unique_agent_daily_metric UNIQUE (agent_id, metric_date)
);

CREATE INDEX IF NOT EXISTS idx_agent_metrics_agent ON agent_daily_metrics(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_metrics_workspace ON agent_daily_metrics(workspace_id);
CREATE INDEX IF NOT EXISTS idx_agent_metrics_date ON agent_daily_metrics(metric_date DESC);

-- ============================================================================
-- ANALYTICS: WORKSPACE DAILY METRICS
-- ============================================================================

CREATE TABLE IF NOT EXISTS workspace_daily_metrics (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    metric_date DATE NOT NULL,

    -- Call Metrics
    total_calls INT DEFAULT 0,
    total_duration_seconds INT DEFAULT 0,
    total_minutes DECIMAL(10,2) DEFAULT 0,

    -- Agent Metrics
    active_agents INT DEFAULT 0,
    total_agents INT DEFAULT 0,

    -- Contact Metrics
    total_contacts INT DEFAULT 0,
    new_contacts INT DEFAULT 0,
    contacts_with_calls INT DEFAULT 0,

    -- Appointment Metrics
    appointments_scheduled INT DEFAULT 0,
    appointments_completed INT DEFAULT 0,
    appointments_cancelled INT DEFAULT 0,

    -- Transaction Metrics
    transactions_created INT DEFAULT 0,
    transactions_won INT DEFAULT 0,
    total_revenue DECIMAL(12,2) DEFAULT 0,

    -- Quality Metrics
    avg_quality_score DECIMAL(3,2),
    avg_customer_satisfaction DECIMAL(3,2),

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT unique_workspace_daily_metric UNIQUE (workspace_id, metric_date)
);

CREATE INDEX IF NOT EXISTS idx_workspace_metrics_workspace ON workspace_daily_metrics(workspace_id);
CREATE INDEX IF NOT EXISTS idx_workspace_metrics_tenant ON workspace_daily_metrics(tenant_id);
CREATE INDEX IF NOT EXISTS idx_workspace_metrics_date ON workspace_daily_metrics(metric_date DESC);

-- ============================================================================
-- TRIGGERS
-- ============================================================================

DROP TRIGGER IF EXISTS update_webhooks_updated_at ON webhooks;
CREATE TRIGGER update_webhooks_updated_at BEFORE UPDATE ON webhooks
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_agent_metrics_updated_at ON agent_daily_metrics;
CREATE TRIGGER update_agent_metrics_updated_at BEFORE UPDATE ON agent_daily_metrics
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_workspace_metrics_updated_at ON workspace_daily_metrics;
CREATE TRIGGER update_workspace_metrics_updated_at BEFORE UPDATE ON workspace_daily_metrics
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- WEBHOOK TRIGGER FUNCTION
-- ============================================================================

CREATE OR REPLACE FUNCTION trigger_webhooks_for_event(
    p_workspace_id UUID,
    p_event_type VARCHAR(100),
    p_event_id UUID,
    p_event_data JSONB
)
RETURNS INT AS $$
DECLARE
    v_webhook RECORD;
    v_delivery_id UUID;
    v_triggered_count INT := 0;
BEGIN
    -- Find all active webhooks listening for this event type
    FOR v_webhook IN
        SELECT id, url, secret_key, http_method, headers, timeout_seconds, retry_count
        FROM webhooks
        WHERE workspace_id = p_workspace_id
            AND is_active = true
            AND deleted_at IS NULL
            AND p_event_type = ANY(events)
    LOOP
        -- Create webhook delivery record
        INSERT INTO webhook_deliveries (
            webhook_id,
            event_type,
            event_id,
            request_url,
            request_method,
            request_headers,
            request_body,
            status,
            max_attempts
        ) VALUES (
            v_webhook.id,
            p_event_type,
            p_event_id,
            v_webhook.url,
            v_webhook.http_method,
            v_webhook.headers,
            p_event_data,
            'pending',
            v_webhook.retry_count
        ) RETURNING id INTO v_delivery_id;

        v_triggered_count := v_triggered_count + 1;

        -- Update webhook statistics
        UPDATE webhooks
        SET total_deliveries = total_deliveries + 1,
            last_triggered_at = CURRENT_TIMESTAMP
        WHERE id = v_webhook.id;
    END LOOP;

    RETURN v_triggered_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- METRICS CALCULATION FUNCTIONS
-- ============================================================================

-- Calculate agent daily metrics for a specific date
CREATE OR REPLACE FUNCTION calculate_agent_daily_metrics(
    p_agent_id UUID,
    p_date DATE
)
RETURNS UUID AS $$
DECLARE
    v_metric_id UUID;
BEGIN
    -- Upsert agent daily metrics
    INSERT INTO agent_daily_metrics (
        agent_id,
        workspace_id,
        metric_date,
        total_calls,
        inbound_calls,
        outbound_calls,
        completed_calls,
        failed_calls,
        total_duration_seconds,
        avg_duration_seconds,
        max_duration_seconds,
        avg_quality_score,
        avg_sentiment_score,
        positive_sentiment_count,
        negative_sentiment_count,
        neutral_sentiment_count,
        successful_outcomes,
        unique_callers
    )
    SELECT
        p_agent_id,
        va.workspace_id,
        p_date,
        COUNT(*),
        COUNT(*) FILTER (WHERE c.direction = 'inbound'),
        COUNT(*) FILTER (WHERE c.direction = 'outbound'),
        COUNT(*) FILTER (WHERE c.call_status = 'completed'),
        COUNT(*) FILTER (WHERE c.call_status = 'failed'),
        SUM(c.duration_seconds),
        AVG(c.duration_seconds)::INT,
        MAX(c.duration_seconds),
        AVG(ca.call_quality_score),
        AVG(ca.sentiment_score),
        COUNT(*) FILTER (WHERE ca.sentiment = 'positive'),
        COUNT(*) FILTER (WHERE ca.sentiment = 'negative'),
        COUNT(*) FILTER (WHERE ca.sentiment = 'neutral'),
        COUNT(*) FILTER (WHERE ca.call_successful = true),
        COUNT(DISTINCT c.caller_phone)
    FROM voice_agents va
    LEFT JOIN calls c ON c.agent_id = va.id
        AND DATE(c.started_at) = p_date
    LEFT JOIN call_analysis ca ON ca.call_id = c.id
    WHERE va.id = p_agent_id
    GROUP BY va.id, va.workspace_id
    ON CONFLICT (agent_id, metric_date) DO UPDATE SET
        total_calls = EXCLUDED.total_calls,
        inbound_calls = EXCLUDED.inbound_calls,
        outbound_calls = EXCLUDED.outbound_calls,
        completed_calls = EXCLUDED.completed_calls,
        failed_calls = EXCLUDED.failed_calls,
        total_duration_seconds = EXCLUDED.total_duration_seconds,
        avg_duration_seconds = EXCLUDED.avg_duration_seconds,
        max_duration_seconds = EXCLUDED.max_duration_seconds,
        avg_quality_score = EXCLUDED.avg_quality_score,
        avg_sentiment_score = EXCLUDED.avg_sentiment_score,
        positive_sentiment_count = EXCLUDED.positive_sentiment_count,
        negative_sentiment_count = EXCLUDED.negative_sentiment_count,
        neutral_sentiment_count = EXCLUDED.neutral_sentiment_count,
        successful_outcomes = EXCLUDED.successful_outcomes,
        unique_callers = EXCLUDED.unique_callers,
        updated_at = CURRENT_TIMESTAMP
    RETURNING id INTO v_metric_id;

    RETURN v_metric_id;
END;
$$ LANGUAGE plpgsql;

-- Calculate workspace daily metrics for a specific date
CREATE OR REPLACE FUNCTION calculate_workspace_daily_metrics(
    p_workspace_id UUID,
    p_date DATE
)
RETURNS UUID AS $$
DECLARE
    v_metric_id UUID;
    v_tenant_id UUID;
BEGIN
    -- Get tenant_id
    SELECT tenant_id INTO v_tenant_id FROM workspaces WHERE id = p_workspace_id;

    -- Upsert workspace daily metrics
    INSERT INTO workspace_daily_metrics (
        workspace_id,
        tenant_id,
        metric_date,
        total_calls,
        total_duration_seconds,
        total_minutes,
        active_agents,
        total_agents,
        total_contacts,
        new_contacts,
        appointments_scheduled,
        transactions_created,
        transactions_won,
        total_revenue,
        avg_quality_score
    )
    SELECT
        p_workspace_id,
        v_tenant_id,
        p_date,
        COUNT(DISTINCT c.id),
        SUM(c.duration_seconds),
        (SUM(c.duration_seconds) / 60.0)::DECIMAL(10,2),
        COUNT(DISTINCT CASE WHEN c.id IS NOT NULL THEN c.agent_id END),
        COUNT(DISTINCT va.id),
        COUNT(DISTINCT con.id),
        COUNT(DISTINCT CASE WHEN DATE(con.created_at) = p_date THEN con.id END),
        COUNT(DISTINCT CASE WHEN DATE(a.created_at) = p_date THEN a.id END),
        COUNT(DISTINCT CASE WHEN DATE(t.created_at) = p_date THEN t.id END),
        COUNT(DISTINCT CASE WHEN DATE(t.closed_at) = p_date AND t.status = 'won' THEN t.id END),
        SUM(CASE WHEN DATE(t.closed_at) = p_date AND t.status = 'won' THEN t.amount ELSE 0 END),
        AVG(ca.call_quality_score)
    FROM workspaces w
    LEFT JOIN voice_agents va ON va.workspace_id = w.id AND va.deleted_at IS NULL
    LEFT JOIN calls c ON c.workspace_id = w.id AND DATE(c.started_at) = p_date
    LEFT JOIN call_analysis ca ON ca.call_id = c.id
    LEFT JOIN contacts con ON con.workspace_id = w.id AND con.deleted_at IS NULL
    LEFT JOIN appointments a ON a.workspace_id = w.id AND a.deleted_at IS NULL
    LEFT JOIN transactions t ON t.workspace_id = w.id AND t.deleted_at IS NULL
    WHERE w.id = p_workspace_id
    GROUP BY w.id
    ON CONFLICT (workspace_id, metric_date) DO UPDATE SET
        total_calls = EXCLUDED.total_calls,
        total_duration_seconds = EXCLUDED.total_duration_seconds,
        total_minutes = EXCLUDED.total_minutes,
        active_agents = EXCLUDED.active_agents,
        total_agents = EXCLUDED.total_agents,
        total_contacts = EXCLUDED.total_contacts,
        new_contacts = EXCLUDED.new_contacts,
        appointments_scheduled = EXCLUDED.appointments_scheduled,
        transactions_created = EXCLUDED.transactions_created,
        transactions_won = EXCLUDED.transactions_won,
        total_revenue = EXCLUDED.total_revenue,
        avg_quality_score = EXCLUDED.avg_quality_score,
        updated_at = CURRENT_TIMESTAMP
    RETURNING id INTO v_metric_id;

    RETURN v_metric_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- VIEWS
-- ============================================================================

-- Webhook delivery status view
CREATE OR REPLACE VIEW v_webhook_deliveries AS
SELECT
    wd.id,
    wd.webhook_id,
    w.name as webhook_name,
    w.workspace_id,
    wd.event_type,
    wd.status,
    wd.response_status_code,
    wd.duration_ms,
    wd.attempt_number,
    wd.max_attempts,
    wd.error_message,
    wd.created_at,
    wd.delivered_at,
    wd.next_retry_at
FROM webhook_deliveries wd
LEFT JOIN webhooks w ON w.id = wd.webhook_id
ORDER BY wd.created_at DESC;

-- Agent performance dashboard view
CREATE OR REPLACE VIEW v_agent_performance AS
SELECT
    va.id as agent_id,
    va.name as agent_name,
    va.workspace_id,
    adm.metric_date,
    adm.total_calls,
    adm.completed_calls,
    adm.avg_duration_seconds,
    adm.avg_quality_score,
    adm.avg_sentiment_score,
    adm.successful_outcomes,
    adm.appointments_booked,
    CASE
        WHEN adm.total_calls > 0
        THEN (adm.completed_calls::DECIMAL / adm.total_calls * 100)::DECIMAL(5,2)
        ELSE 0
    END as completion_rate,
    CASE
        WHEN adm.total_calls > 0
        THEN (adm.successful_outcomes::DECIMAL / adm.total_calls * 100)::DECIMAL(5,2)
        ELSE 0
    END as success_rate
FROM voice_agents va
LEFT JOIN agent_daily_metrics adm ON adm.agent_id = va.id
WHERE va.deleted_at IS NULL
ORDER BY adm.metric_date DESC, adm.total_calls DESC;

-- Workspace analytics dashboard view
CREATE OR REPLACE VIEW v_workspace_analytics AS
SELECT
    w.id as workspace_id,
    w.name as workspace_name,
    wdm.metric_date,
    wdm.total_calls,
    wdm.total_minutes,
    wdm.active_agents,
    wdm.total_contacts,
    wdm.new_contacts,
    wdm.appointments_scheduled,
    wdm.transactions_won,
    wdm.total_revenue,
    wdm.avg_quality_score
FROM workspaces w
LEFT JOIN workspace_daily_metrics wdm ON wdm.workspace_id = w.id
WHERE w.deleted_at IS NULL
ORDER BY wdm.metric_date DESC;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE webhooks IS 'Webhook configuration for real-time event notifications';
COMMENT ON TABLE webhook_deliveries IS 'Webhook delivery attempts and responses';
COMMENT ON TABLE agent_daily_metrics IS 'Daily performance metrics per voice agent';
COMMENT ON TABLE workspace_daily_metrics IS 'Daily performance metrics per workspace';

COMMENT ON FUNCTION trigger_webhooks_for_event IS 'Queue webhook deliveries for an event';
COMMENT ON FUNCTION calculate_agent_daily_metrics IS 'Calculate and store daily agent metrics';
COMMENT ON FUNCTION calculate_workspace_daily_metrics IS 'Calculate and store daily workspace metrics';

-- ============================================================================
COMMENT ON SCHEMA public IS 'Tier 4: Advanced Features (Webhooks & Analytics)';
