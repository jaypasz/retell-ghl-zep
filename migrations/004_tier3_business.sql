-- ============================================================================
-- TIER 3: BUSINESS FEATURES
-- ============================================================================
-- CRM and sales functionality for voice AI platform
-- Includes: Transactions/Deals, Call Events, Tags, Notes, API Keys
-- Excludes: Knowledge Base with vector embeddings (using Zep instead)
-- ============================================================================

-- ============================================================================
-- TRANSACTIONS (Deals/Sales)
-- ============================================================================

CREATE TABLE IF NOT EXISTS transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    contact_id UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,

    -- Transaction Info
    name VARCHAR(255) NOT NULL,
    description TEXT,

    -- Financial
    amount DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    currency VARCHAR(3) DEFAULT 'USD',

    -- Status & Stage
    status VARCHAR(50) NOT NULL DEFAULT 'open',
    stage VARCHAR(100),
    probability INT DEFAULT 0,

    -- Timeline
    expected_close_date DATE,
    closed_at TIMESTAMP WITH TIME ZONE,

    -- Related Records
    call_id UUID REFERENCES calls(id) ON DELETE SET NULL,
    appointment_id UUID REFERENCES appointments(id) ON DELETE SET NULL,

    -- Assignment
    assigned_to UUID REFERENCES users(id) ON DELETE SET NULL,

    -- External CRM Integration (GHL complement)
    external_crm_type VARCHAR(50),
    external_crm_id VARCHAR(255),
    external_crm_synced_at TIMESTAMP WITH TIME ZONE,

    -- Metadata
    tags TEXT[],
    custom_fields JSONB DEFAULT '{}',
    metadata JSONB DEFAULT '{}',

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,

    CONSTRAINT valid_transaction_status CHECK (
        status IN ('open', 'won', 'lost', 'abandoned', 'on_hold')
    ),
    CONSTRAINT valid_probability CHECK (probability >= 0 AND probability <= 100)
);

CREATE INDEX IF NOT EXISTS idx_transactions_workspace ON transactions(workspace_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_transactions_contact ON transactions(contact_id);
CREATE INDEX IF NOT EXISTS idx_transactions_status ON transactions(status);
CREATE INDEX IF NOT EXISTS idx_transactions_assigned ON transactions(assigned_to);
CREATE INDEX IF NOT EXISTS idx_transactions_close_date ON transactions(expected_close_date);
CREATE INDEX IF NOT EXISTS idx_transactions_external_crm ON transactions(external_crm_type, external_crm_id);

-- ============================================================================
-- CALL EVENTS (Detailed Call Tracking)
-- ============================================================================

CREATE TABLE IF NOT EXISTS call_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,

    -- Event Info
    event_type VARCHAR(100) NOT NULL,
    event_name VARCHAR(255),

    -- Timing
    occurred_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    timestamp_offset_seconds DECIMAL(10,3),

    -- Event Data
    event_data JSONB DEFAULT '{}',

    -- Metadata
    metadata JSONB DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_call_events_call_id ON call_events(call_id);
CREATE INDEX IF NOT EXISTS idx_call_events_type ON call_events(event_type);
CREATE INDEX IF NOT EXISTS idx_call_events_occurred ON call_events(occurred_at);

-- Common event types:
-- 'call_started', 'call_ended', 'transfer_initiated', 'transfer_completed',
-- 'hold_started', 'hold_ended', 'recording_started', 'recording_stopped',
-- 'dtmf_pressed', 'intent_detected', 'error_occurred'

-- ============================================================================
-- CALL TAGS
-- ============================================================================

CREATE TABLE IF NOT EXISTS call_tags (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,

    -- Tag Info
    tag VARCHAR(100) NOT NULL,
    tag_type VARCHAR(50) DEFAULT 'manual',

    -- Who Tagged
    tagged_by UUID REFERENCES users(id) ON DELETE SET NULL,
    tagged_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    -- Metadata
    metadata JSONB DEFAULT '{}',

    CONSTRAINT unique_call_tag UNIQUE (call_id, tag),
    CONSTRAINT valid_tag_type CHECK (tag_type IN ('manual', 'auto', 'ai_generated'))
);

CREATE INDEX IF NOT EXISTS idx_call_tags_call_id ON call_tags(call_id);
CREATE INDEX IF NOT EXISTS idx_call_tags_tag ON call_tags(tag);
CREATE INDEX IF NOT EXISTS idx_call_tags_type ON call_tags(tag_type);

-- ============================================================================
-- CALL NOTES
-- ============================================================================

CREATE TABLE IF NOT EXISTS call_notes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,

    -- Note Content
    note TEXT NOT NULL,
    note_type VARCHAR(50) DEFAULT 'general',

    -- Author
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_by_name VARCHAR(255),

    -- Visibility
    is_internal BOOLEAN DEFAULT false,

    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,

    CONSTRAINT valid_note_type CHECK (
        note_type IN ('general', 'follow_up', 'complaint', 'escalation', 'resolution', 'other')
    )
);

CREATE INDEX IF NOT EXISTS idx_call_notes_call_id ON call_notes(call_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_call_notes_created_by ON call_notes(created_by);
CREATE INDEX IF NOT EXISTS idx_call_notes_type ON call_notes(note_type);

-- ============================================================================
-- API KEYS
-- ============================================================================

CREATE TABLE IF NOT EXISTS api_keys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    -- Key Info
    name VARCHAR(255) NOT NULL,
    description TEXT,
    key_hash VARCHAR(255) NOT NULL UNIQUE,
    key_prefix VARCHAR(20) NOT NULL,

    -- Permissions
    scopes TEXT[] NOT NULL DEFAULT '{}',
    rate_limit_per_minute INT DEFAULT 60,

    -- Status
    is_active BOOLEAN DEFAULT true,
    last_used_at TIMESTAMP WITH TIME ZONE,

    -- Expiration
    expires_at TIMESTAMP WITH TIME ZONE,

    -- Owner
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX IF NOT EXISTS idx_api_keys_workspace ON api_keys(workspace_id) WHERE deleted_at IS NULL AND is_active = true;
CREATE INDEX IF NOT EXISTS idx_api_keys_hash ON api_keys(key_hash) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_api_keys_expires ON api_keys(expires_at) WHERE expires_at IS NOT NULL;

-- ============================================================================
-- AGENT KNOWLEDGE BASE (Without Vector Embeddings)
-- ============================================================================
-- Note: Using Zep for semantic memory, this is for simple FAQ/reference data

CREATE TABLE IF NOT EXISTS agent_knowledge_base (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL REFERENCES voice_agents(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    -- Content
    title VARCHAR(500) NOT NULL,
    content TEXT NOT NULL,
    category VARCHAR(100),

    -- Search Optimization (using pg_trgm for full-text search instead of vectors)
    search_keywords TEXT[],

    -- Metadata
    source_url TEXT,
    tags TEXT[],
    priority INT DEFAULT 0,

    -- Status
    is_active BOOLEAN DEFAULT true,

    -- Timestamps
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX IF NOT EXISTS idx_knowledge_base_agent ON agent_knowledge_base(agent_id) WHERE deleted_at IS NULL AND is_active = true;
CREATE INDEX IF NOT EXISTS idx_knowledge_base_workspace ON agent_knowledge_base(workspace_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_knowledge_base_category ON agent_knowledge_base(category);
CREATE INDEX IF NOT EXISTS idx_knowledge_base_priority ON agent_knowledge_base(priority DESC);

-- Full-text search index using pg_trgm (instead of pgvector)
CREATE INDEX IF NOT EXISTS idx_knowledge_base_content_search ON agent_knowledge_base
    USING gin(to_tsvector('english', title || ' ' || content));

CREATE INDEX IF NOT EXISTS idx_knowledge_base_keywords ON agent_knowledge_base USING gin(search_keywords);

-- ============================================================================
-- TRIGGERS
-- ============================================================================

DROP TRIGGER IF EXISTS update_transactions_updated_at ON transactions;
CREATE TRIGGER update_transactions_updated_at BEFORE UPDATE ON transactions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_call_notes_updated_at ON call_notes;
CREATE TRIGGER update_call_notes_updated_at BEFORE UPDATE ON call_notes
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_api_keys_updated_at ON api_keys;
CREATE TRIGGER update_api_keys_updated_at BEFORE UPDATE ON api_keys
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_knowledge_base_updated_at ON agent_knowledge_base;
CREATE TRIGGER update_knowledge_base_updated_at BEFORE UPDATE ON agent_knowledge_base
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- AUDIT LOG TRIGGERS FOR BUSINESS ENTITIES
-- ============================================================================

-- Transaction audit logging
CREATE OR REPLACE FUNCTION log_transaction_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_action VARCHAR(100);
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_action := 'transaction_created';
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.status != NEW.status THEN
            v_action := 'transaction_status_changed';
        ELSIF OLD.amount != NEW.amount THEN
            v_action := 'transaction_amount_updated';
        ELSE
            v_action := 'transaction_updated';
        END IF;
    ELSIF TG_OP = 'DELETE' THEN
        v_action := 'transaction_deleted';
    END IF;

    INSERT INTO audit_logs (
        workspace_id,
        action,
        entity_type,
        entity_id,
        old_values,
        new_values,
        changes
    ) VALUES (
        COALESCE(NEW.workspace_id, OLD.workspace_id),
        v_action,
        'transaction',
        COALESCE(NEW.id, OLD.id),
        CASE WHEN TG_OP != 'INSERT' THEN to_jsonb(OLD) ELSE NULL END,
        CASE WHEN TG_OP != 'DELETE' THEN to_jsonb(NEW) ELSE NULL END,
        jsonb_build_object(
            'status_changed', CASE WHEN TG_OP = 'UPDATE' THEN OLD.status != NEW.status ELSE false END,
            'amount_changed', CASE WHEN TG_OP = 'UPDATE' THEN OLD.amount != NEW.amount ELSE false END
        )
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS transactions_audit_trigger ON transactions;
CREATE TRIGGER transactions_audit_trigger
    AFTER INSERT OR UPDATE OR DELETE ON transactions
    FOR EACH ROW EXECUTE FUNCTION log_transaction_changes();

-- ============================================================================
-- VIEWS
-- ============================================================================

-- Transaction pipeline view
CREATE OR REPLACE VIEW v_transaction_pipeline AS
SELECT
    t.id,
    t.workspace_id,
    t.name,
    t.amount,
    t.currency,
    t.status,
    t.stage,
    t.probability,
    t.expected_close_date,
    t.created_at,
    c.full_name as contact_name,
    c.phone as contact_phone,
    c.email as contact_email,
    u.name as assigned_to_name,
    COUNT(DISTINCT ci.id) as interaction_count,
    MAX(ci.created_at) as last_interaction_at
FROM transactions t
LEFT JOIN contacts c ON c.id = t.contact_id
LEFT JOIN users u ON u.id = t.assigned_to
LEFT JOIN contact_interactions ci ON ci.contact_id = t.contact_id
WHERE t.deleted_at IS NULL
GROUP BY t.id, c.full_name, c.phone, c.email, u.name;

-- Call engagement metrics view
CREATE OR REPLACE VIEW v_call_engagement AS
SELECT
    c.id as call_id,
    c.workspace_id,
    c.agent_id,
    c.contact_id,
    c.duration_seconds,
    c.started_at,
    COUNT(DISTINCT ce.id) as event_count,
    COUNT(DISTINCT ct.id) as tag_count,
    COUNT(DISTINCT cn.id) as note_count,
    ARRAY_AGG(DISTINCT ct.tag) FILTER (WHERE ct.tag IS NOT NULL) as tags
FROM calls c
LEFT JOIN call_events ce ON ce.call_id = c.id
LEFT JOIN call_tags ct ON ct.call_id = c.id
LEFT JOIN call_notes cn ON cn.call_id = c.id AND cn.deleted_at IS NULL
GROUP BY c.id;

-- Knowledge base search helper view
CREATE OR REPLACE VIEW v_knowledge_base_search AS
SELECT
    kb.id,
    kb.agent_id,
    kb.workspace_id,
    kb.title,
    kb.content,
    kb.category,
    kb.search_keywords,
    kb.priority,
    kb.created_at,
    va.name as agent_name,
    to_tsvector('english', kb.title || ' ' || kb.content) as search_vector
FROM agent_knowledge_base kb
LEFT JOIN voice_agents va ON va.id = kb.agent_id
WHERE kb.deleted_at IS NULL AND kb.is_active = true;

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Function to search knowledge base using full-text search
CREATE OR REPLACE FUNCTION search_knowledge_base(
    p_agent_id UUID,
    p_query TEXT,
    p_limit INT DEFAULT 5
)
RETURNS TABLE (
    id UUID,
    title VARCHAR(500),
    content TEXT,
    category VARCHAR(100),
    relevance_score REAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        kb.id,
        kb.title,
        kb.content,
        kb.category,
        ts_rank(
            to_tsvector('english', kb.title || ' ' || kb.content),
            plainto_tsquery('english', p_query)
        ) as relevance_score
    FROM agent_knowledge_base kb
    WHERE kb.agent_id = p_agent_id
        AND kb.deleted_at IS NULL
        AND kb.is_active = true
        AND (
            to_tsvector('english', kb.title || ' ' || kb.content) @@ plainto_tsquery('english', p_query)
            OR kb.search_keywords && string_to_array(lower(p_query), ' ')
        )
    ORDER BY relevance_score DESC, kb.priority DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- Function to get contact revenue summary
CREATE OR REPLACE FUNCTION get_contact_revenue_summary(p_contact_id UUID)
RETURNS TABLE (
    total_revenue DECIMAL(12,2),
    won_count INT,
    open_count INT,
    lost_count INT,
    average_deal_size DECIMAL(12,2)
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        COALESCE(SUM(CASE WHEN status = 'won' THEN amount ELSE 0 END), 0) as total_revenue,
        COUNT(*) FILTER (WHERE status = 'won')::INT as won_count,
        COUNT(*) FILTER (WHERE status = 'open')::INT as open_count,
        COUNT(*) FILTER (WHERE status = 'lost')::INT as lost_count,
        COALESCE(AVG(amount) FILTER (WHERE status = 'won'), 0) as average_deal_size
    FROM transactions
    WHERE contact_id = p_contact_id AND deleted_at IS NULL;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE transactions IS 'Sales deals and revenue tracking (complements GHL)';
COMMENT ON TABLE call_events IS 'Detailed event stream for call monitoring';
COMMENT ON TABLE call_tags IS 'Manual and AI-generated tags for call categorization';
COMMENT ON TABLE call_notes IS 'User-created notes and annotations for calls';
COMMENT ON TABLE api_keys IS 'Programmatic API access management';
COMMENT ON TABLE agent_knowledge_base IS 'Agent FAQ and reference data (uses full-text search, not vectors)';

COMMENT ON FUNCTION search_knowledge_base IS 'Full-text search for agent knowledge base (alternative to RAG)';
COMMENT ON FUNCTION get_contact_revenue_summary IS 'Calculate revenue metrics for a contact';

-- ============================================================================
COMMENT ON SCHEMA public IS 'Tier 3: Business Features (GHL-Complementary, Zep for Memory)';
