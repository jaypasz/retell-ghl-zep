-- ============================================================================
-- FULL VOICE AI PLATFORM MIGRATION (Modified for Voice Agent SaaS)
-- ============================================================================
-- Applied to: Voice Agent SaaS (https://upocdtuhywtmhjtpzdtf.supabase.co)
--
-- Modifications from original:
-- 1. Removed pgvector extension (using Zep for knowledge base)
-- 2. Removed agent_knowledge_base table (using Zep)
-- 3. Added calendar_provider choice (ghl, cal_com) to workspace and appointments
-- 4. Added agent_scripts table for custom Python scripts per agent/workspace
-- ============================================================================

-- Enable required extensions (no pgvector - using Zep for KB)
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- For full-text search

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
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- Workspace Info
    name VARCHAR(255) NOT NULL,
    description TEXT,
    slug VARCHAR(100) NOT NULL,

    -- Owner
    owner_id UUID REFERENCES users(id) ON DELETE SET NULL,

    -- Calendar Provider Configuration (GHL or Cal.com)
    calendar_provider VARCHAR(50) DEFAULT 'ghl',
    calendar_provider_config JSONB DEFAULT '{}',
    -- For GHL: {"api_key": "...", "location_id": "...", "calendar_id": "..."}
    -- For Cal.com: {"api_key": "...", "event_type_id": "...", "username": "..."}

    -- Settings
    settings JSONB DEFAULT '{}',

    -- Status
    is_active BOOLEAN DEFAULT true,

    -- Metadata
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,

    CONSTRAINT unique_workspace_slug_per_tenant UNIQUE (tenant_id, slug),
    CONSTRAINT valid_calendar_provider CHECK (calendar_provider IN ('ghl', 'cal_com', 'none'))
);

-- Workspace Members
CREATE TABLE IF NOT EXISTS workspace_members (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
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
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
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

    -- Zep Integration (for knowledge base)
    zep_collection_id VARCHAR(255),

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
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
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

-- ============================================================================
-- STEP 4: AGENT SCRIPTS TABLE (Custom Python scripts per agent/workspace)
-- ============================================================================

-- Agent Scripts - Store custom Python scripts for unique integrations
CREATE TABLE IF NOT EXISTS agent_scripts (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    agent_id UUID REFERENCES voice_agents(id) ON DELETE CASCADE, -- NULL means workspace-wide script

    -- Script Identity
    name VARCHAR(255) NOT NULL,
    description TEXT,
    script_type VARCHAR(50) NOT NULL DEFAULT 'integration',

    -- Script Content
    python_code TEXT NOT NULL,
    code_version INT DEFAULT 1,

    -- Trigger Configuration
    trigger_event VARCHAR(100), -- e.g., 'call_started', 'call_ended', 'appointment_booked', 'manual'
    trigger_conditions JSONB DEFAULT '{}',

    -- Execution Settings
    timeout_seconds INT DEFAULT 30,
    max_retries INT DEFAULT 3,
    retry_delay_seconds INT DEFAULT 5,

    -- Required Environment/Dependencies
    required_env_vars TEXT[], -- List of required environment variable names
    python_dependencies TEXT[], -- pip packages required

    -- Status & Validation
    is_active BOOLEAN DEFAULT false,
    is_validated BOOLEAN DEFAULT false,
    validation_errors TEXT[],
    last_validated_at TIMESTAMP WITH TIME ZONE,

    -- Usage Statistics
    total_executions INT DEFAULT 0,
    successful_executions INT DEFAULT 0,
    failed_executions INT DEFAULT 0,
    average_execution_time_ms INT,
    last_executed_at TIMESTAMP WITH TIME ZONE,
    last_execution_error TEXT,

    -- Sandbox/Security
    sandbox_mode BOOLEAN DEFAULT true, -- Run in restricted environment
    allowed_modules TEXT[], -- Whitelist of allowed Python modules

    -- Version Control
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    last_modified_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,

    CONSTRAINT unique_script_name_per_workspace UNIQUE (workspace_id, name),
    CONSTRAINT valid_script_type CHECK (script_type IN ('integration', 'automation', 'data_transform', 'webhook_handler', 'custom'))
);

-- Script Execution History
CREATE TABLE IF NOT EXISTS script_executions (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    script_id UUID NOT NULL REFERENCES agent_scripts(id) ON DELETE CASCADE,

    -- Execution Context
    call_id UUID, -- Will add FK later after calls table
    contact_id UUID, -- Will add FK later after contacts table

    -- Trigger Info
    triggered_by VARCHAR(50) NOT NULL, -- 'event', 'manual', 'schedule'
    trigger_data JSONB DEFAULT '{}',

    -- Execution Status
    status VARCHAR(50) NOT NULL DEFAULT 'pending',

    -- Timing
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP WITH TIME ZONE,
    duration_ms INT,

    -- Results
    input_data JSONB,
    output_data JSONB,
    error_message TEXT,
    error_stack_trace TEXT,

    -- Retry Info
    attempt_number INT DEFAULT 1,
    is_retry BOOLEAN DEFAULT false,
    parent_execution_id UUID REFERENCES script_executions(id) ON DELETE SET NULL,

    -- Logs
    execution_logs TEXT[],

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT valid_execution_status CHECK (status IN ('pending', 'running', 'completed', 'failed', 'timeout', 'cancelled'))
);

-- ... (remaining tables as applied)
-- See full migration in Supabase dashboard

-- ============================================================================
-- COMPLETION
-- ============================================================================

COMMENT ON SCHEMA public IS 'Voice Agent SaaS Platform - Full Schema Migration with Zep KB, GHL/Cal.com calendars, and custom scripts';
COMMENT ON TABLE agent_scripts IS 'Custom Python scripts for unique integrations per agent or workspace';
COMMENT ON TABLE script_executions IS 'Execution history and logs for agent scripts';
