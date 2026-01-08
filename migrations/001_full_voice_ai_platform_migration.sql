-- ============================================================================
-- FULL VOICE AI PLATFORM MIGRATION
-- ============================================================================
-- This migration upgrades the simple appointment booking schema to the full
-- multi-tenant Voice AI SaaS platform schema.
--
-- Current State: 1 tenant, 2 users, 0 appointments
-- Target: Full Retell AI-based voice agent platform
-- ============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- For full-text search
CREATE EXTENSION IF NOT EXISTS "vector"; -- For embeddings (requires pgvector)

-- ============================================================================
-- STEP 1: ALTER EXISTING TABLES
-- ============================================================================

-- Upgrade tenants table
ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS slug VARCHAR(100) UNIQUE,
    ADD COLUMN IF NOT EXISTS company_name VARCHAR(255),
    ADD COLUMN IF NOT EXISTS subscription_tier VARCHAR(50) NOT NULL DEFAULT 'free',
    ADD COLUMN IF NOT EXISTS subscription_status VARCHAR(50) NOT NULL DEFAULT 'trial',
    ADD COLUMN IF NOT EXISTS billing_email VARCHAR(255),
    ADD COLUMN IF NOT EXISTS stripe_customer_id VARCHAR(255) UNIQUE,
    ADD COLUMN IF NOT EXISTS max_workspaces INT DEFAULT 1,
    ADD COLUMN IF NOT EXISTS max_agents_per_workspace INT DEFAULT 3,
    ADD COLUMN IF NOT EXISTS max_monthly_minutes INT DEFAULT 1000,
    ADD COLUMN IF NOT EXISTS max_team_members INT DEFAULT 5,
    ADD COLUMN IF NOT EXISTS current_monthly_minutes INT DEFAULT 0,
    ADD COLUMN IF NOT EXISTS total_calls INT DEFAULT 0,
    ADD COLUMN IF NOT EXISTS timezone VARCHAR(50) DEFAULT 'UTC',
    ADD COLUMN IF NOT EXISTS language VARCHAR(10) DEFAULT 'en',
    ADD COLUMN IF NOT EXISTS settings JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE;

-- Add constraints to tenants
ALTER TABLE tenants ADD CONSTRAINT valid_subscription_tier
    CHECK (subscription_tier IN ('free', 'starter', 'professional', 'enterprise'));

ALTER TABLE tenants ADD CONSTRAINT valid_subscription_status
    CHECK (subscription_status IN ('trial', 'active', 'past_due', 'cancelled', 'suspended'));

-- Generate slugs for existing tenants (from name)
UPDATE tenants SET slug = lower(replace(name, ' ', '-')) WHERE slug IS NULL;

-- Upgrade users table
ALTER TABLE users
    RENAME COLUMN encrypted_password TO password_hash;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS email_verified BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS phone VARCHAR(50),
    ADD COLUMN IF NOT EXISTS avatar_url TEXT,
    ADD COLUMN IF NOT EXISTS permissions JSONB DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS oauth_provider VARCHAR(50),
    ADD COLUMN IF NOT EXISTS oauth_id VARCHAR(255),
    ADD COLUMN IF NOT EXISTS preferences JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS notification_settings JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS status VARCHAR(50) DEFAULT 'active',
    ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE;

-- Update existing users to have default role
UPDATE users SET role = 'admin' WHERE role IS NULL OR role = '';

ALTER TABLE users ADD CONSTRAINT valid_role
    CHECK (role IN ('super_admin', 'admin', 'manager', 'member', 'viewer'));

ALTER TABLE users ADD CONSTRAINT valid_status
    CHECK (status IN ('active', 'inactive', 'suspended'));

-- ============================================================================
-- STEP 2: CREATE NEW CORE TABLES
-- ============================================================================

-- Workspaces (Organization units within a tenant)
CREATE TABLE IF NOT EXISTS workspaces (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- Workspace Info
    name VARCHAR(255) NOT NULL,
    description TEXT,
    slug VARCHAR(100) NOT NULL,

    -- Owner
    owner_id UUID REFERENCES users(id) ON DELETE SET NULL,

    -- Settings
    settings JSONB DEFAULT '{}',

    -- Status
    is_active BOOLEAN DEFAULT true,

    -- Metadata
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,

    CONSTRAINT unique_workspace_slug_per_tenant UNIQUE (tenant_id, slug)
);

-- Workspace Members
CREATE TABLE IF NOT EXISTS workspace_members (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    role VARCHAR(50) NOT NULL DEFAULT 'member',
    permissions JSONB DEFAULT '[]',

    joined_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT unique_workspace_member UNIQUE (workspace_id, user_id),
    CONSTRAINT valid_workspace_role CHECK (role IN ('admin', 'manager', 'member', 'viewer'))
);

-- ============================================================================
-- STEP 3: VOICE AGENT TABLES
-- ============================================================================

-- Voice Agents
CREATE TABLE IF NOT EXISTS voice_agents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    -- Agent Identity
    name VARCHAR(255) NOT NULL,
    description TEXT,
    agent_type VARCHAR(50) NOT NULL DEFAULT 'conversational',

    -- Retell AI Integration
    retell_agent_id VARCHAR(255) UNIQUE,
    retell_llm_id VARCHAR(255),

    -- LLM Configuration
    llm_provider VARCHAR(50) DEFAULT 'openai',
    llm_model VARCHAR(100) DEFAULT 'gpt-4',
    llm_temperature DECIMAL(3,2) DEFAULT 0.7,
    llm_max_tokens INT DEFAULT 1000,

    -- Prompt Configuration
    system_prompt TEXT,
    initial_message TEXT,
    fallback_message TEXT,

    -- Voice Configuration
    voice_id VARCHAR(255) DEFAULT 'elevenlabs-rachel',
    voice_provider VARCHAR(50) DEFAULT 'elevenlabs',
    voice_speed DECIMAL(3,2) DEFAULT 1.0,
    voice_temperature DECIMAL(3,2) DEFAULT 1.0,

    -- Conversation Settings
    language VARCHAR(10) DEFAULT 'en',
    interruption_sensitivity DECIMAL(3,2) DEFAULT 0.5,
    responsiveness DECIMAL(3,2) DEFAULT 1.0,
    enable_transcription BOOLEAN DEFAULT true,
    enable_recording BOOLEAN DEFAULT true,

    -- Routing & Transfer
    enable_human_handoff BOOLEAN DEFAULT false,
    handoff_phone_number VARCHAR(50),
    handoff_criteria JSONB DEFAULT '{}',

    -- Business Hours
    business_hours JSONB DEFAULT '{}',
    timezone VARCHAR(50) DEFAULT 'UTC',

    -- Call Limits & Controls
    max_call_duration_seconds INT DEFAULT 3600,
    max_concurrent_calls INT DEFAULT 10,
    cost_per_minute DECIMAL(10,4) DEFAULT 0.10,

    -- Webhook Configuration
    webhook_url TEXT,
    webhook_events TEXT[],
    webhook_secret VARCHAR(255),

    -- Status
    is_active BOOLEAN DEFAULT true,
    is_published BOOLEAN DEFAULT false,

    -- Metadata
    tags TEXT[],
    metadata JSONB DEFAULT '{}',
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- Agent Phone Numbers
CREATE TABLE IF NOT EXISTS agent_phone_numbers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL REFERENCES voice_agents(id) ON DELETE CASCADE,

    phone_number VARCHAR(50) NOT NULL UNIQUE,
    country_code VARCHAR(10),
    number_type VARCHAR(50) DEFAULT 'local',

    provider VARCHAR(50),
    provider_sid VARCHAR(255),

    is_primary BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,

    capabilities JSONB DEFAULT '{}',
    monthly_cost DECIMAL(10,2),

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Agent Knowledge Base
CREATE TABLE IF NOT EXISTS agent_knowledge_base (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL REFERENCES voice_agents(id) ON DELETE CASCADE,

    title VARCHAR(255) NOT NULL,
    content TEXT NOT NULL,
    content_type VARCHAR(50) DEFAULT 'text',

    -- Vector embeddings for RAG (requires pgvector extension)
    -- embedding vector(1536),

    -- Metadata
    source_url TEXT,
    tags TEXT[],
    is_active BOOLEAN DEFAULT true,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- STEP 4: CALL MANAGEMENT TABLES
-- ============================================================================

-- Calls
CREATE TABLE IF NOT EXISTS calls (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL REFERENCES voice_agents(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    -- Retell Integration
    retell_call_id VARCHAR(255) UNIQUE,

    -- Call Participants
    caller_phone VARCHAR(50),
    caller_name VARCHAR(255),
    agent_phone VARCHAR(50),

    -- Call Details
    direction VARCHAR(20) NOT NULL,
    call_status VARCHAR(50) NOT NULL,

    -- Timing
    started_at TIMESTAMP WITH TIME ZONE,
    ended_at TIMESTAMP WITH TIME ZONE,
    duration_seconds INT,
    talk_time_seconds INT,
    wait_time_seconds INT,

    -- Call Outcome
    disconnection_reason VARCHAR(100),
    call_outcome VARCHAR(100),

    -- Quality Metrics
    call_rating INT CHECK (call_rating >= 1 AND call_rating <= 5),
    audio_quality_score DECIMAL(3,2),
    latency_ms INT,

    -- Costs
    cost_amount DECIMAL(10,4),
    cost_currency VARCHAR(10) DEFAULT 'USD',

    -- Media
    recording_url TEXT,
    recording_duration_seconds INT,

    -- Related Contact (will add FK after contacts table is created)
    contact_id UUID,

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Call Transcripts
CREATE TABLE IF NOT EXISTS call_transcripts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,

    -- Transcript Content
    full_transcript TEXT,
    transcript_format VARCHAR(20) DEFAULT 'text',

    -- Language
    language VARCHAR(10) DEFAULT 'en',
    confidence_score DECIMAL(3,2),

    -- Processing
    processed_by VARCHAR(50),
    processing_duration_ms INT,

    -- Word Count
    word_count INT,
    speaker_count INT,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Call Transcript Segments
CREATE TABLE IF NOT EXISTS call_transcript_segments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    transcript_id UUID NOT NULL REFERENCES call_transcripts(id) ON DELETE CASCADE,
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,

    -- Segment Info
    sequence_number INT NOT NULL,
    speaker VARCHAR(20) NOT NULL,

    -- Content
    text TEXT NOT NULL,
    start_time_ms INT NOT NULL,
    end_time_ms INT NOT NULL,

    -- Confidence
    confidence_score DECIMAL(3,2),

    -- Metadata
    sentiment VARCHAR(20),
    emotion VARCHAR(50),

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT unique_segment UNIQUE (transcript_id, sequence_number)
);

-- Call Analysis
CREATE TABLE IF NOT EXISTS call_analysis (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL UNIQUE REFERENCES calls(id) ON DELETE CASCADE,

    -- Summary
    summary TEXT,
    key_points TEXT[],
    action_items TEXT[],

    -- Sentiment Analysis
    overall_sentiment VARCHAR(20),
    sentiment_score DECIMAL(3,2),
    customer_satisfaction_score INT CHECK (customer_satisfaction_score >= 1 AND customer_satisfaction_score <= 10),

    -- Conversation Metrics
    agent_talk_time_percent DECIMAL(5,2),
    customer_talk_time_percent DECIMAL(5,2),
    silence_time_percent DECIMAL(5,2),
    interruption_count INT DEFAULT 0,
    talk_speed_wpm INT,

    -- Emotion Analysis
    detected_emotions JSONB,
    emotion_changes JSONB,

    -- Intent & Outcome
    primary_intent VARCHAR(100),
    secondary_intents TEXT[],
    intent_confidence DECIMAL(3,2),
    call_successful BOOLEAN,
    resolution_status VARCHAR(50),

    -- Compliance & Quality
    compliance_score DECIMAL(3,2),
    compliance_issues TEXT[],
    quality_score DECIMAL(3,2),
    agent_performance_score DECIMAL(3,2),

    -- Topics & Categories
    detected_topics TEXT[],
    categories TEXT[],
    tags TEXT[],

    -- Extracted Data
    extracted_entities JSONB,
    extracted_phone_numbers TEXT[],
    extracted_emails TEXT[],

    -- AI Analysis Metadata
    analyzed_by VARCHAR(50),
    analysis_version VARCHAR(20),
    analysis_duration_ms INT,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Call Events
CREATE TABLE IF NOT EXISTS call_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,

    event_type VARCHAR(100) NOT NULL,
    event_timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Event Details
    event_data JSONB DEFAULT '{}',

    -- Sequence
    sequence_number INT,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT ordered_events UNIQUE (call_id, sequence_number)
);

-- Call Tags
CREATE TABLE IF NOT EXISTS call_tags (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,

    tag VARCHAR(100) NOT NULL,
    tagged_by UUID REFERENCES users(id) ON DELETE SET NULL,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT unique_call_tag UNIQUE (call_id, tag)
);

-- Call Notes
CREATE TABLE IF NOT EXISTS call_notes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,

    note TEXT NOT NULL,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- STEP 5: CRM TABLES
-- ============================================================================

-- Contacts
CREATE TABLE IF NOT EXISTS contacts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    -- Personal Info
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    full_name VARCHAR(255),
    company VARCHAR(255),
    job_title VARCHAR(255),

    -- Contact Info
    email VARCHAR(255),
    phone VARCHAR(50),
    alternate_phone VARCHAR(50),

    -- Address
    address_line1 VARCHAR(255),
    address_line2 VARCHAR(255),
    city VARCHAR(100),
    state VARCHAR(100),
    postal_code VARCHAR(20),
    country VARCHAR(100),

    -- Social
    linkedin_url TEXT,
    twitter_handle VARCHAR(100),
    website TEXT,

    -- Contact Status
    contact_status VARCHAR(50) DEFAULT 'active',
    lead_status VARCHAR(50),
    lead_source VARCHAR(100),

    -- Scoring
    lead_score INT DEFAULT 0,
    engagement_score DECIMAL(5,2) DEFAULT 0,

    -- Relationships
    account_manager_id UUID REFERENCES users(id) ON DELETE SET NULL,

    -- External CRM IDs
    external_crm_type VARCHAR(50),
    external_crm_id VARCHAR(255),

    -- Communication Preferences
    preferred_contact_method VARCHAR(50) DEFAULT 'phone',
    timezone VARCHAR(50),
    language VARCHAR(10) DEFAULT 'en',
    communication_preferences JSONB DEFAULT '{}',

    -- Statistics
    total_calls INT DEFAULT 0,
    last_call_at TIMESTAMP WITH TIME ZONE,
    total_appointments INT DEFAULT 0,
    last_appointment_at TIMESTAMP WITH TIME ZONE,
    total_transactions INT DEFAULT 0,
    lifetime_value DECIMAL(10,2) DEFAULT 0,

    -- Tags & Segments
    tags TEXT[],
    segments TEXT[],

    -- Custom Fields
    custom_fields JSONB DEFAULT '{}',

    -- Notes
    notes TEXT,

    -- Metadata
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- Add foreign key from calls to contacts
ALTER TABLE calls ADD CONSTRAINT fk_calls_contact
    FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE SET NULL;

-- Contact Interactions
CREATE TABLE IF NOT EXISTS contact_interactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    contact_id UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    interaction_type VARCHAR(50) NOT NULL,
    direction VARCHAR(20),

    -- Related Records
    call_id UUID REFERENCES calls(id) ON DELETE SET NULL,

    -- Content
    subject VARCHAR(255),
    description TEXT,
    outcome VARCHAR(100),

    -- Participants
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,

    -- Timing
    occurred_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    duration_seconds INT,

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Upgrade appointments table
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

-- Rename tenant_id to match schema (keeping it for now for backward compatibility)
-- ALTER TABLE appointments RENAME COLUMN tenant_id TO workspace_id; -- Skip if you want to keep both

-- Populate scheduled_start and scheduled_end from existing date/time fields
UPDATE appointments
SET
    scheduled_start = (appointment_date + appointment_time)::TIMESTAMP WITH TIME ZONE,
    scheduled_end = (appointment_date + appointment_time + INTERVAL '1 hour')::TIMESTAMP WITH TIME ZONE,
    duration_minutes = 60,
    title = COALESCE(name, 'Appointment'),
    location_details = address
WHERE scheduled_start IS NULL;

-- Transactions
CREATE TABLE IF NOT EXISTS transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    contact_id UUID REFERENCES contacts(id) ON DELETE SET NULL,

    -- Transaction Details
    transaction_type VARCHAR(50) NOT NULL,
    title VARCHAR(255) NOT NULL,
    description TEXT,

    -- Financial
    amount DECIMAL(10,2) NOT NULL,
    currency VARCHAR(10) DEFAULT 'USD',

    -- Status & Stage
    status VARCHAR(50) DEFAULT 'open',
    stage VARCHAR(100),
    probability INT CHECK (probability >= 0 AND probability <= 100),

    -- Dates
    expected_close_date DATE,
    closed_date DATE,

    -- Relationships
    owner_id UUID REFERENCES users(id) ON DELETE SET NULL,

    -- Integration
    external_crm_type VARCHAR(50),
    external_transaction_id VARCHAR(255),

    -- Related Records
    source_call_id UUID REFERENCES calls(id) ON DELETE SET NULL,

    -- Metadata
    tags TEXT[],
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- STEP 6: WORKFLOW SYSTEM
-- ============================================================================

-- Workflows
CREATE TABLE IF NOT EXISTS workflows (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    agent_id UUID REFERENCES voice_agents(id) ON DELETE SET NULL,

    -- Workflow Info
    name VARCHAR(255) NOT NULL,
    description TEXT,
    workflow_type VARCHAR(50) NOT NULL,

    -- Trigger Configuration
    trigger_type VARCHAR(50) NOT NULL,
    trigger_config JSONB NOT NULL DEFAULT '{}',
    trigger_conditions JSONB DEFAULT '[]',

    -- Python Code
    python_code TEXT NOT NULL,
    code_version INT DEFAULT 1,

    -- Execution Settings
    timeout_seconds INT DEFAULT 30,
    max_retries INT DEFAULT 3,
    retry_delay_seconds INT DEFAULT 5,

    -- Status
    is_active BOOLEAN DEFAULT true,
    is_validated BOOLEAN DEFAULT false,
    validation_errors TEXT[],

    -- Usage Statistics
    total_executions INT DEFAULT 0,
    successful_executions INT DEFAULT 0,
    failed_executions INT DEFAULT 0,
    average_execution_time_ms INT,
    last_executed_at TIMESTAMP WITH TIME ZONE,

    -- Environment
    environment_variables JSONB DEFAULT '{}',
    required_integrations TEXT[],

    -- Version Control
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- Workflow Executions
CREATE TABLE IF NOT EXISTS workflow_executions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,

    -- Execution Context
    call_id UUID REFERENCES calls(id) ON DELETE SET NULL,
    contact_id UUID REFERENCES contacts(id) ON DELETE SET NULL,

    -- Trigger Info
    triggered_by VARCHAR(50) NOT NULL,
    trigger_data JSONB DEFAULT '{}',

    -- Execution Status
    status VARCHAR(50) NOT NULL DEFAULT 'pending',

    -- Timing
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP WITH TIME ZONE,
    duration_ms INT,

    -- Results
    output JSONB,
    error_message TEXT,
    error_stack_trace TEXT,

    -- Retry Info
    attempt_number INT DEFAULT 1,
    is_retry BOOLEAN DEFAULT false,
    parent_execution_id UUID REFERENCES workflow_executions(id) ON DELETE SET NULL,

    -- Logs
    execution_logs TEXT[],

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Workflow Integrations
CREATE TABLE IF NOT EXISTS workflow_integrations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    -- Integration Info
    integration_name VARCHAR(100) NOT NULL,
    integration_type VARCHAR(50) NOT NULL,

    -- Credentials (Encrypted at application level)
    credentials_encrypted BYTEA NOT NULL,
    credential_type VARCHAR(50) DEFAULT 'api_key',

    -- OAuth specific
    oauth_access_token TEXT,
    oauth_refresh_token TEXT,
    oauth_token_expires_at TIMESTAMP WITH TIME ZONE,

    -- Configuration
    configuration JSONB DEFAULT '{}',

    -- Status
    is_active BOOLEAN DEFAULT true,
    last_validated_at TIMESTAMP WITH TIME ZONE,
    validation_status VARCHAR(50),

    -- Usage
    last_used_at TIMESTAMP WITH TIME ZONE,

    -- Metadata
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT unique_workspace_integration UNIQUE (workspace_id, integration_name)
);

-- ============================================================================
-- STEP 7: ANALYTICS & METRICS
-- ============================================================================

-- Agent Daily Metrics
CREATE TABLE IF NOT EXISTS agent_daily_metrics (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL REFERENCES voice_agents(id) ON DELETE CASCADE,
    metric_date DATE NOT NULL,

    -- Call Volume
    total_calls INT DEFAULT 0,
    inbound_calls INT DEFAULT 0,
    outbound_calls INT DEFAULT 0,
    completed_calls INT DEFAULT 0,
    failed_calls INT DEFAULT 0,

    -- Duration
    total_talk_time_seconds INT DEFAULT 0,
    average_call_duration_seconds INT DEFAULT 0,

    -- Quality
    average_call_rating DECIMAL(3,2),
    average_quality_score DECIMAL(3,2),
    customer_satisfaction_score DECIMAL(3,2),

    -- Outcomes
    successful_outcomes INT DEFAULT 0,
    transfers INT DEFAULT 0,
    voicemails INT DEFAULT 0,

    -- Lead Metrics
    leads_captured INT DEFAULT 0,
    appointments_booked INT DEFAULT 0,
    deals_created INT DEFAULT 0,

    -- Costs
    total_cost DECIMAL(10,2) DEFAULT 0,
    average_cost_per_call DECIMAL(10,2),

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT unique_agent_daily_metric UNIQUE (agent_id, metric_date)
);

-- Workspace Daily Metrics
CREATE TABLE IF NOT EXISTS workspace_daily_metrics (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    metric_date DATE NOT NULL,

    -- Call Volume
    total_calls INT DEFAULT 0,
    total_minutes INT DEFAULT 0,

    -- Agents
    active_agents INT DEFAULT 0,

    -- Contacts
    new_contacts INT DEFAULT 0,
    total_contacts INT DEFAULT 0,

    -- Appointments
    appointments_booked INT DEFAULT 0,
    appointments_completed INT DEFAULT 0,

    -- Revenue
    total_revenue DECIMAL(10,2) DEFAULT 0,
    total_cost DECIMAL(10,2) DEFAULT 0,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT unique_workspace_daily_metric UNIQUE (workspace_id, metric_date)
);

-- ============================================================================
-- STEP 8: SYSTEM TABLES
-- ============================================================================

-- API Keys
CREATE TABLE IF NOT EXISTS api_keys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    name VARCHAR(255) NOT NULL,
    key_hash VARCHAR(255) NOT NULL UNIQUE,
    key_prefix VARCHAR(20),

    -- Permissions
    permissions TEXT[] DEFAULT ARRAY['read'],
    scopes JSONB DEFAULT '{}',

    -- Status
    is_active BOOLEAN DEFAULT true,
    expires_at TIMESTAMP WITH TIME ZONE,
    last_used_at TIMESTAMP WITH TIME ZONE,

    -- Usage Stats
    total_requests INT DEFAULT 0,

    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    revoked_at TIMESTAMP WITH TIME ZONE
);

-- Webhooks
CREATE TABLE IF NOT EXISTS webhooks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    name VARCHAR(255) NOT NULL,
    url TEXT NOT NULL,
    secret VARCHAR(255),

    -- Events to subscribe to
    events TEXT[] NOT NULL,

    -- Status
    is_active BOOLEAN DEFAULT true,

    -- Delivery Stats
    total_deliveries INT DEFAULT 0,
    successful_deliveries INT DEFAULT 0,
    failed_deliveries INT DEFAULT 0,
    last_delivery_at TIMESTAMP WITH TIME ZONE,
    last_delivery_status VARCHAR(50),

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Webhook Deliveries
CREATE TABLE IF NOT EXISTS webhook_deliveries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    webhook_id UUID NOT NULL REFERENCES webhooks(id) ON DELETE CASCADE,

    event_type VARCHAR(100) NOT NULL,
    payload JSONB NOT NULL,

    -- Delivery Info
    status VARCHAR(50) NOT NULL,
    http_status_code INT,
    response_body TEXT,

    -- Timing
    delivered_at TIMESTAMP WITH TIME ZONE,
    response_time_ms INT,

    -- Retry Info
    attempt_number INT DEFAULT 1,
    next_retry_at TIMESTAMP WITH TIME ZONE,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Audit Log
CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    workspace_id UUID REFERENCES workspaces(id) ON DELETE CASCADE,

    -- Actor
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    user_email VARCHAR(255),

    -- Action
    action VARCHAR(100) NOT NULL,
    resource_type VARCHAR(50) NOT NULL,
    resource_id UUID,

    -- Details
    changes JSONB,
    metadata JSONB DEFAULT '{}',

    -- Context
    ip_address INET,
    user_agent TEXT,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- STEP 9: INDEXES
-- ============================================================================

-- Tenants
CREATE INDEX IF NOT EXISTS idx_tenants_subscription_status ON tenants(subscription_status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tenants_created_at ON tenants(created_at);

-- Users
CREATE INDEX IF NOT EXISTS idx_users_tenant_id ON users(tenant_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);

-- Workspaces
CREATE INDEX IF NOT EXISTS idx_workspaces_tenant_id ON workspaces(tenant_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_workspaces_owner_id ON workspaces(owner_id);

-- Workspace Members
CREATE INDEX IF NOT EXISTS idx_workspace_members_workspace_id ON workspace_members(workspace_id);
CREATE INDEX IF NOT EXISTS idx_workspace_members_user_id ON workspace_members(user_id);

-- Voice Agents
CREATE INDEX IF NOT EXISTS idx_voice_agents_workspace_id ON voice_agents(workspace_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_voice_agents_retell_agent_id ON voice_agents(retell_agent_id);
CREATE INDEX IF NOT EXISTS idx_voice_agents_is_active ON voice_agents(is_active);

-- Calls
CREATE INDEX IF NOT EXISTS idx_calls_agent_id ON calls(agent_id);
CREATE INDEX IF NOT EXISTS idx_calls_workspace_id ON calls(workspace_id);
CREATE INDEX IF NOT EXISTS idx_calls_contact_id ON calls(contact_id);
CREATE INDEX IF NOT EXISTS idx_calls_started_at ON calls(started_at);
CREATE INDEX IF NOT EXISTS idx_calls_status ON calls(call_status);
CREATE INDEX IF NOT EXISTS idx_calls_direction ON calls(direction);
CREATE INDEX IF NOT EXISTS idx_calls_caller_phone ON calls(caller_phone);

-- Call Transcripts
CREATE INDEX IF NOT EXISTS idx_call_transcripts_call_id ON call_transcripts(call_id);

-- Call Transcript Segments
CREATE INDEX IF NOT EXISTS idx_transcript_segments_transcript_id ON call_transcript_segments(transcript_id);
CREATE INDEX IF NOT EXISTS idx_transcript_segments_call_id ON call_transcript_segments(call_id);

-- Call Analysis
CREATE INDEX IF NOT EXISTS idx_call_analysis_call_id ON call_analysis(call_id);
CREATE INDEX IF NOT EXISTS idx_call_analysis_overall_sentiment ON call_analysis(overall_sentiment);

-- Call Events
CREATE INDEX IF NOT EXISTS idx_call_events_call_id ON call_events(call_id);
CREATE INDEX IF NOT EXISTS idx_call_events_type_timestamp ON call_events(event_type, event_timestamp);

-- Contacts
CREATE INDEX IF NOT EXISTS idx_contacts_workspace_id ON contacts(workspace_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_contacts_email ON contacts(email);
CREATE INDEX IF NOT EXISTS idx_contacts_phone ON contacts(phone);
CREATE INDEX IF NOT EXISTS idx_contacts_lead_status ON contacts(lead_status);
CREATE INDEX IF NOT EXISTS idx_contacts_external_crm ON contacts(external_crm_type, external_crm_id);
CREATE INDEX IF NOT EXISTS idx_contacts_tags ON contacts USING GIN(tags);

-- Contact Interactions
CREATE INDEX IF NOT EXISTS idx_contact_interactions_contact_id ON contact_interactions(contact_id);
CREATE INDEX IF NOT EXISTS idx_contact_interactions_workspace_id ON contact_interactions(workspace_id);
CREATE INDEX IF NOT EXISTS idx_contact_interactions_call_id ON contact_interactions(call_id);
CREATE INDEX IF NOT EXISTS idx_contact_interactions_occurred_at ON contact_interactions(occurred_at);

-- Appointments
CREATE INDEX IF NOT EXISTS idx_appointments_workspace_id_new ON appointments(workspace_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_appointments_contact_id ON appointments(contact_id);
CREATE INDEX IF NOT EXISTS idx_appointments_agent_id ON appointments(agent_id);
CREATE INDEX IF NOT EXISTS idx_appointments_scheduled_start ON appointments(scheduled_start);
CREATE INDEX IF NOT EXISTS idx_appointments_status ON appointments(status);

-- Transactions
CREATE INDEX IF NOT EXISTS idx_transactions_workspace_id ON transactions(workspace_id);
CREATE INDEX IF NOT EXISTS idx_transactions_contact_id ON transactions(contact_id);
CREATE INDEX IF NOT EXISTS idx_transactions_status ON transactions(status);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at);

-- Workflows
CREATE INDEX IF NOT EXISTS idx_workflows_workspace_id ON workflows(workspace_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_workflows_agent_id ON workflows(agent_id);
CREATE INDEX IF NOT EXISTS idx_workflows_is_active ON workflows(is_active);

-- Workflow Executions
CREATE INDEX IF NOT EXISTS idx_workflow_executions_workflow_id ON workflow_executions(workflow_id);
CREATE INDEX IF NOT EXISTS idx_workflow_executions_call_id ON workflow_executions(call_id);
CREATE INDEX IF NOT EXISTS idx_workflow_executions_status ON workflow_executions(status);
CREATE INDEX IF NOT EXISTS idx_workflow_executions_started_at ON workflow_executions(started_at);

-- Workflow Integrations
CREATE INDEX IF NOT EXISTS idx_workflow_integrations_workspace_id ON workflow_integrations(workspace_id);
CREATE INDEX IF NOT EXISTS idx_workflow_integrations_name ON workflow_integrations(integration_name);

-- Agent Daily Metrics
CREATE INDEX IF NOT EXISTS idx_agent_daily_metrics_agent_id ON agent_daily_metrics(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_daily_metrics_date ON agent_daily_metrics(metric_date);

-- Workspace Daily Metrics
CREATE INDEX IF NOT EXISTS idx_workspace_daily_metrics_workspace_id ON workspace_daily_metrics(workspace_id);
CREATE INDEX IF NOT EXISTS idx_workspace_daily_metrics_date ON workspace_daily_metrics(metric_date);

-- Audit Logs
CREATE INDEX IF NOT EXISTS idx_audit_logs_tenant_id ON audit_logs(tenant_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_workspace_id ON audit_logs(workspace_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at);

-- Full-text search indexes
CREATE INDEX IF NOT EXISTS idx_contacts_search ON contacts USING gin(to_tsvector('english',
    coalesce(full_name, '') || ' ' ||
    coalesce(email, '') || ' ' ||
    coalesce(company, '')
));

CREATE INDEX IF NOT EXISTS idx_call_transcripts_search ON call_transcripts USING gin(to_tsvector('english', coalesce(full_transcript, '')));

-- ============================================================================
-- STEP 10: TRIGGERS
-- ============================================================================

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Apply updated_at trigger to relevant tables
DROP TRIGGER IF EXISTS update_tenants_updated_at ON tenants;
CREATE TRIGGER update_tenants_updated_at BEFORE UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_users_updated_at ON users;
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_workspaces_updated_at ON workspaces;
CREATE TRIGGER update_workspaces_updated_at BEFORE UPDATE ON workspaces
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_voice_agents_updated_at ON voice_agents;
CREATE TRIGGER update_voice_agents_updated_at BEFORE UPDATE ON voice_agents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_calls_updated_at ON calls;
CREATE TRIGGER update_calls_updated_at BEFORE UPDATE ON calls
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_call_analysis_updated_at ON call_analysis;
CREATE TRIGGER update_call_analysis_updated_at BEFORE UPDATE ON call_analysis
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_contacts_updated_at ON contacts;
CREATE TRIGGER update_contacts_updated_at BEFORE UPDATE ON contacts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_appointments_updated_at ON appointments;
CREATE TRIGGER update_appointments_updated_at BEFORE UPDATE ON appointments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_transactions_updated_at ON transactions;
CREATE TRIGGER update_transactions_updated_at BEFORE UPDATE ON transactions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_workflows_updated_at ON workflows;
CREATE TRIGGER update_workflows_updated_at BEFORE UPDATE ON workflows
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Function to increment total calls on contact
CREATE OR REPLACE FUNCTION increment_contact_calls()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.contact_id IS NOT NULL AND NEW.call_status = 'completed' THEN
        UPDATE contacts
        SET total_calls = total_calls + 1,
            last_call_at = NEW.ended_at
        WHERE id = NEW.contact_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_contact_call_stats ON calls;
CREATE TRIGGER update_contact_call_stats AFTER INSERT OR UPDATE ON calls
    FOR EACH ROW EXECUTE FUNCTION increment_contact_calls();

-- ============================================================================
-- STEP 11: VIEWS
-- ============================================================================

-- Agent Performance View
CREATE OR REPLACE VIEW agent_performance_summary AS
SELECT
    va.id as agent_id,
    va.name as agent_name,
    va.workspace_id,
    COUNT(c.id) as total_calls,
    COUNT(CASE WHEN c.call_status = 'completed' THEN 1 END) as completed_calls,
    ROUND(AVG(c.duration_seconds)) as avg_duration_seconds,
    ROUND(AVG(ca.sentiment_score)::numeric, 2) as avg_sentiment_score,
    ROUND(AVG(ca.customer_satisfaction_score)::numeric, 2) as avg_csat,
    ROUND(AVG(c.call_rating)::numeric, 2) as avg_call_rating,
    SUM(c.cost_amount) as total_cost
FROM voice_agents va
LEFT JOIN calls c ON va.id = c.agent_id AND c.started_at > CURRENT_DATE - INTERVAL '30 days'
LEFT JOIN call_analysis ca ON c.id = ca.call_id
WHERE va.deleted_at IS NULL
GROUP BY va.id, va.name, va.workspace_id;

-- Recent Contact Activity View
CREATE OR REPLACE VIEW contact_recent_activity AS
SELECT
    c.id as contact_id,
    c.full_name,
    c.email,
    c.phone,
    c.workspace_id,
    COUNT(DISTINCT calls.id) as call_count,
    COUNT(DISTINCT a.id) as appointment_count,
    COUNT(DISTINCT t.id) as transaction_count,
    MAX(calls.started_at) as last_call_at,
    MAX(a.scheduled_start) as next_appointment_at,
    SUM(t.amount) as total_transaction_value
FROM contacts c
LEFT JOIN calls ON c.id = calls.contact_id
LEFT JOIN appointments a ON c.id = a.contact_id
LEFT JOIN transactions t ON c.id = t.contact_id
WHERE c.deleted_at IS NULL
GROUP BY c.id, c.full_name, c.email, c.phone, c.workspace_id;

-- ============================================================================
-- STEP 12: DATA MIGRATION
-- ============================================================================

-- Create a default workspace for each existing tenant
INSERT INTO workspaces (tenant_id, name, slug, owner_id, is_active)
SELECT
    t.id,
    t.name || ' Workspace',
    'default',
    (SELECT id FROM users WHERE tenant_id = t.id ORDER BY created_at LIMIT 1),
    true
FROM tenants t
WHERE NOT EXISTS (SELECT 1 FROM workspaces w WHERE w.tenant_id = t.id);

-- Add all existing users to their tenant's default workspace
INSERT INTO workspace_members (workspace_id, user_id, role)
SELECT
    w.id,
    u.id,
    CASE
        WHEN u.role = 'admin' THEN 'admin'
        WHEN u.role = 'super_admin' THEN 'admin'
        ELSE 'member'
    END
FROM users u
JOIN workspaces w ON w.tenant_id = u.tenant_id AND w.slug = 'default'
WHERE NOT EXISTS (
    SELECT 1 FROM workspace_members wm
    WHERE wm.workspace_id = w.id AND wm.user_id = u.id
);

-- ============================================================================
-- COMPLETION
-- ============================================================================

COMMENT ON SCHEMA public IS 'Multi-tenant Voice AI SaaS Platform - Full Schema Migration Completed';
