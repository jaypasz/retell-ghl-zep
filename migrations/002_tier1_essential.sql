-- ============================================================================
-- TIER 1: ESSENTIAL FEATURES
-- ============================================================================
-- Essential tables for basic Retell AI voice agent platform
-- Includes: Multi-tenancy, Voice Agents, Calls, Transcripts, Contacts
-- ============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ============================================================================
-- UPGRADE EXISTING TABLES
-- ============================================================================

-- Upgrade tenants table (minimal essential fields)
ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS slug VARCHAR(100) UNIQUE,
    ADD COLUMN IF NOT EXISTS subscription_tier VARCHAR(50) NOT NULL DEFAULT 'free',
    ADD COLUMN IF NOT EXISTS subscription_status VARCHAR(50) NOT NULL DEFAULT 'active',
    ADD COLUMN IF NOT EXISTS max_workspaces INT DEFAULT 1,
    ADD COLUMN IF NOT EXISTS timezone VARCHAR(50) DEFAULT 'UTC',
    ADD COLUMN IF NOT EXISTS settings JSONB DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE;

-- Generate slugs for existing tenants
UPDATE tenants SET slug = lower(replace(name, ' ', '-')) WHERE slug IS NULL;

-- Add constraints
ALTER TABLE tenants ADD CONSTRAINT IF NOT EXISTS valid_subscription_tier
    CHECK (subscription_tier IN ('free', 'starter', 'professional', 'enterprise'));

-- Upgrade users table (essential fields)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'users' AND column_name = 'encrypted_password') THEN
        ALTER TABLE users RENAME COLUMN encrypted_password TO password_hash;
    END IF;
END $$;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS phone VARCHAR(50),
    ADD COLUMN IF NOT EXISTS status VARCHAR(50) DEFAULT 'active',
    ADD COLUMN IF NOT EXISTS permissions JSONB DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE;

-- Update existing users role
UPDATE users SET role = 'admin' WHERE role IS NULL OR role = '';

-- ============================================================================
-- WORKSPACES
-- ============================================================================

CREATE TABLE IF NOT EXISTS workspaces (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(100) NOT NULL,
    owner_id UUID REFERENCES users(id) ON DELETE SET NULL,
    settings JSONB DEFAULT '{}',
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT unique_workspace_slug_per_tenant UNIQUE (tenant_id, slug)
);

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
-- VOICE AGENTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS voice_agents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,

    -- Retell AI Integration
    retell_agent_id VARCHAR(255) UNIQUE,
    retell_llm_id VARCHAR(255),

    -- LLM Configuration
    llm_provider VARCHAR(50) DEFAULT 'openai',
    llm_model VARCHAR(100) DEFAULT 'gpt-4',
    system_prompt TEXT,

    -- Voice Configuration
    voice_id VARCHAR(255) DEFAULT 'elevenlabs-rachel',
    voice_provider VARCHAR(50) DEFAULT 'elevenlabs',

    -- Settings
    language VARCHAR(10) DEFAULT 'en',
    enable_transcription BOOLEAN DEFAULT true,
    enable_recording BOOLEAN DEFAULT true,
    webhook_url TEXT,

    -- Status
    is_active BOOLEAN DEFAULT true,

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE IF NOT EXISTS agent_phone_numbers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL REFERENCES voice_agents(id) ON DELETE CASCADE,
    phone_number VARCHAR(50) NOT NULL UNIQUE,
    is_primary BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- CONTACTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS contacts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    -- Personal Info
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    full_name VARCHAR(255),
    email VARCHAR(255),
    phone VARCHAR(50),

    -- External CRM
    external_crm_type VARCHAR(50),
    external_crm_id VARCHAR(255),

    -- Statistics
    total_calls INT DEFAULT 0,
    last_call_at TIMESTAMP WITH TIME ZONE,

    -- Custom Fields
    custom_fields JSONB DEFAULT '{}',
    tags TEXT[],

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX IF NOT EXISTS idx_contacts_workspace_id ON contacts(workspace_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_contacts_phone ON contacts(phone);
CREATE INDEX IF NOT EXISTS idx_contacts_email ON contacts(email);

-- ============================================================================
-- CALLS
-- ============================================================================

CREATE TABLE IF NOT EXISTS calls (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL REFERENCES voice_agents(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    contact_id UUID REFERENCES contacts(id) ON DELETE SET NULL,

    -- Retell Integration
    retell_call_id VARCHAR(255) UNIQUE,

    -- Call Info
    caller_phone VARCHAR(50),
    caller_name VARCHAR(255),
    direction VARCHAR(20) NOT NULL,
    call_status VARCHAR(50) NOT NULL,

    -- Timing
    started_at TIMESTAMP WITH TIME ZONE,
    ended_at TIMESTAMP WITH TIME ZONE,
    duration_seconds INT,

    -- Media
    recording_url TEXT,

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_calls_agent_id ON calls(agent_id);
CREATE INDEX IF NOT EXISTS idx_calls_workspace_id ON calls(workspace_id);
CREATE INDEX IF NOT EXISTS idx_calls_contact_id ON calls(contact_id);
CREATE INDEX IF NOT EXISTS idx_calls_started_at ON calls(started_at);
CREATE INDEX IF NOT EXISTS idx_calls_caller_phone ON calls(caller_phone);

-- ============================================================================
-- CALL TRANSCRIPTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS call_transcripts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
    full_transcript TEXT,
    language VARCHAR(10) DEFAULT 'en',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_call_transcripts_call_id ON call_transcripts(call_id);

-- ============================================================================
-- TRIGGERS
-- ============================================================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

DROP TRIGGER IF EXISTS update_workspaces_updated_at ON workspaces;
CREATE TRIGGER update_workspaces_updated_at BEFORE UPDATE ON workspaces
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_voice_agents_updated_at ON voice_agents;
CREATE TRIGGER update_voice_agents_updated_at BEFORE UPDATE ON voice_agents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_contacts_updated_at ON contacts;
CREATE TRIGGER update_contacts_updated_at BEFORE UPDATE ON contacts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_calls_updated_at ON calls;
CREATE TRIGGER update_calls_updated_at BEFORE UPDATE ON calls
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- DATA MIGRATION
-- ============================================================================

-- Create default workspace for each tenant
INSERT INTO workspaces (tenant_id, name, slug, owner_id, is_active)
SELECT
    t.id,
    t.name || ' Default',
    'default',
    (SELECT id FROM users WHERE tenant_id = t.id ORDER BY created_at LIMIT 1),
    true
FROM tenants t
WHERE NOT EXISTS (SELECT 1 FROM workspaces w WHERE w.tenant_id = t.id)
ON CONFLICT DO NOTHING;

-- Add users to workspaces
INSERT INTO workspace_members (workspace_id, user_id, role)
SELECT
    w.id,
    u.id,
    CASE WHEN u.role = 'admin' THEN 'admin' ELSE 'member' END
FROM users u
JOIN workspaces w ON w.tenant_id = u.tenant_id AND w.slug = 'default'
WHERE NOT EXISTS (
    SELECT 1 FROM workspace_members wm
    WHERE wm.workspace_id = w.id AND wm.user_id = u.id
)
ON CONFLICT DO NOTHING;

-- ============================================================================
COMMENT ON SCHEMA public IS 'Tier 1: Essential Voice AI Platform Features';
