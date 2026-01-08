# Voice AI Platform Feature Guide

## Current State Analysis

**Your Remote Database:**
- 1 tenant
- 2 users
- 0 appointments
- 4 tables total (tenants, users, appointments, appointment_history)

**Your Current FastAPI App:**
- Integrates Retell AI voice agents
- Uses Zep for memory management
- Syncs with Go High Level (GHL) CRM
- Handles appointment booking via GHL calendars

## Feature Prioritization Matrix

Choose which features you need based on your use case:

### ✅ TIER 1: ESSENTIAL (Must Have)
**Status:** Required for basic Retell AI integration

| Feature | Tables | Why You Need It |
|---------|--------|-----------------|
| **Multi-tenant Foundation** | `tenants`, `users`, `workspaces`, `workspace_members` | Isolate customer data, manage users |
| **Voice Agents** | `voice_agents`, `agent_phone_numbers` | Core Retell AI agent configuration |
| **Call Management** | `calls`, `call_transcripts` | Track calls, store transcripts |
| **Basic Contacts** | `contacts` | Link callers to contact records |

**Migration:** `002_tier1_essential.sql`

---

### 🔥 TIER 2: HIGHLY RECOMMENDED (Should Have)
**Status:** Makes your platform production-ready

| Feature | Tables | Why You Need It |
|---------|--------|-----------------|
| **Call Analysis** | `call_analysis`, `call_transcript_segments` | AI sentiment analysis, quality scoring |
| **Appointments (Enhanced)** | Upgraded `appointments` table | Rich scheduling with multiple location types |
| **Contact Interactions** | `contact_interactions` | Track all touchpoints beyond calls |
| **Audit Logs** | `audit_logs` | Security, compliance, debugging |

**Migration:** `003_tier2_recommended.sql`

---

### 💼 TIER 3: BUSINESS FEATURES (Nice to Have)
**Status:** For CRM/sales functionality

| Feature | Tables | Why You Need It |
|---------|--------|-----------------|
| **Transactions/Deals** | `transactions` | Track sales, revenue |
| **Agent Knowledge Base** | `agent_knowledge_base` | RAG/semantic search for agents |
| **Call Events & Tags** | `call_events`, `call_tags`, `call_notes` | Detailed tracking, user annotations |
| **API Keys** | `api_keys` | Programmatic access |

**Migration:** `004_tier3_business.sql`

---

### ⚙️ TIER 4: ADVANCED AUTOMATION (Power User)
**Status:** For custom workflows and integrations

| Feature | Tables | Why You Need It |
|---------|--------|-----------------|
| **Workflows** | `workflows`, `workflow_executions`, `workflow_integrations` | Custom Python automation |
| **Webhooks** | `webhooks`, `webhook_deliveries` | Real-time event notifications |
| **Analytics** | `agent_daily_metrics`, `workspace_daily_metrics` | Performance dashboards |

**Migration:** `005_tier4_advanced.sql`

---

## Recommended Migration Path

### Option A: "Start Simple, Scale Up"
**Best for:** Early-stage products, MVPs

1. ✅ Run Tier 1 migration (essential tables)
2. 🔥 Add Tier 2 when you have paying customers
3. 💼 Add Tier 3 when you need CRM features
4. ⚙️ Add Tier 4 when you need automation

### Option B: "Production Ready from Day 1"
**Best for:** Established products, SaaS platforms

1. Run combined migration: Tier 1 + Tier 2
2. Add Tier 3 & 4 as needed

### Option C: "All-In Full Platform"
**Best for:** Enterprise, full-featured platforms

1. Run full migration (`001_full_voice_ai_platform_migration.sql`)
2. All features enabled immediately

---

## Integration with Your Current FastAPI App

### Current App Architecture
```
Retell Webhook → FastAPI → Zep Memory + GHL CRM
```

### With Full Schema
```
Retell Webhook → FastAPI → Supabase → Zep (optional) + GHL (optional)
                             ↓
                      Your own CRM + Workflows
```

### What You'll Need to Update

#### 1. **Environment Variables** (add to `.env`)
```bash
# Supabase (if not already configured)
SUPABASE_URL=your-project-url
SUPABASE_KEY=your-anon-key
SUPABASE_SERVICE_KEY=your-service-role-key

# Existing (keep these)
ZEP_API_KEY=...
GHL_API_KEY=...
RETELL_API_KEY=...
```

#### 2. **Database Client** (add to `main.py`)
```python
from supabase import create_client, Client

supabase: Client = create_client(
    os.getenv("SUPABASE_URL"),
    os.getenv("SUPABASE_SERVICE_KEY")
)
```

#### 3. **Modify `/retell/inbound` Endpoint**

**Before (current):**
```python
@app.post("/retell/inbound")
async def retell_inbound_call(request: RetellInboundRequest):
    # Query Zep
    # Upsert GHL contact
    # Return dynamic_variables
```

**After (with new schema):**
```python
@app.post("/retell/inbound")
async def retell_inbound_call(request: RetellInboundRequest):
    # 1. Create/update contact in Supabase contacts table
    # 2. Create call record in Supabase calls table
    # 3. Query Zep (optional - can use contact.custom_fields instead)
    # 4. Sync to GHL (optional - can manage contacts in Supabase)
    # 5. Return dynamic_variables
```

#### 4. **New Endpoint: Store Call Results**

```python
@app.post("/retell/call-analysis")
async def store_call_analysis(call_data: dict):
    """Store call analysis in call_analysis table"""
    # Store transcript in call_transcripts
    # Store analysis in call_analysis
    # Update contact stats
```

---

## Data Migration Strategy

### Current Appointments → New Schema

Your `appointment_history` table is **unique to your remote schema** - the comprehensive schema doesn't have it. Here's what to do:

#### Option 1: Keep Both (Hybrid)
- Keep your current `appointments` and `appointment_history` tables
- Add new comprehensive tables alongside
- **Pro:** No data loss, backward compatible
- **Con:** Some redundancy

#### Option 2: Merge into Audit Logs
- Migrate `appointment_history` → `audit_logs` table
- Use audit_logs for all change tracking (not just appointments)
- **Pro:** Centralized audit trail
- **Con:** Requires data transformation

#### Option 3: Enhance Appointments
- Keep `appointment_history` as-is
- Enhance `appointments` with new columns
- **Pro:** Preserves your existing pattern
- **Con:** Doesn't follow full schema

---

## Cost & Performance Considerations

### Database Size Estimates (per 1,000 calls/month)

| Feature Set | Storage | Queries/Month | Supabase Free Tier |
|-------------|---------|---------------|-------------------|
| Tier 1 Only | ~50MB | ~10,000 | ✅ Fits easily |
| Tier 1 + 2 | ~200MB | ~50,000 | ✅ Still OK |
| Full Platform | ~500MB | ~100,000 | ⚠️ May need Pro ($25/mo) |

### Indexing Impact
- Full migration adds **40+ indexes**
- Faster queries, slower writes
- Recommended for read-heavy workloads (dashboards, analytics)

---

## Quick Start Recommendations

### For Your Use Case (Retell + Zep + GHL)

**Recommended:** Start with **Tier 1 + Tier 2**

**Why:**
- ✅ Stores all call/transcript data
- ✅ Enables call analysis and sentiment
- ✅ Enhanced appointments (vs your basic table)
- ✅ Contacts table (can replace or complement GHL)
- ✅ Audit trail for compliance
- ❌ Skip workflows (use your FastAPI endpoints instead)
- ❌ Skip metrics (can add later)

**Migration Steps:**
1. Back up your current database
2. Run `002_tier1_essential.sql`
3. Run `003_tier2_recommended.sql`
4. Update your FastAPI app to write to new tables
5. Test with a few calls
6. Gradually phase out GHL for contacts (optional)

---

## Next Steps

1. **Choose your tier** (Recommended: Tier 1 + 2)
2. **Review the migration SQL** (I'll create separate files for each tier)
3. **Test in a dev/staging environment first**
4. **Update your FastAPI app** (I can help with this)
5. **Deploy to production**

---

## Your Configuration Answers ✅

1. **GHL CRM Integration:** ✅ **COMPLEMENT** - GHL remains source of truth, Supabase for analytics
2. **Workflows in Database:** ✅ **NO** - Handled in FastAPI (existing approach)
3. **Appointment History:** ✅ **MIGRATED** to `audit_logs` (centralized audit trail)
4. **Vector Embeddings (RAG):** ✅ **NO** - Using Zep for memory, full-text search for knowledge base

## Your Custom Migration Files

Based on your requirements, the following migrations have been created:

### 📁 [002_tier1_essential.sql](002_tier1_essential.sql)
**Essential Foundation**
- ✅ Multi-tenant foundation (tenants, users, workspaces)
- ✅ Voice agents configuration (Retell AI integration)
- ✅ Call management (calls, transcripts)
- ✅ Basic contacts (with GHL external_crm_id field)

### 📁 [003_tier2_recommended.sql](003_tier2_recommended.sql) ⭐ **CUSTOMIZED**
**Production-Ready Features**
- ✅ Call analysis (AI sentiment, quality scoring)
- ✅ Call transcript segments (turn-by-turn)
- ✅ Contact interactions (all touchpoints)
- ✅ Enhanced appointments (upgraded from basic table)
- ✅ **Audit logs** (replaces appointment_history)
- ✅ **Automatic appointment change tracking**
- ❌ No workflows (you handle in FastAPI)
- ❌ No vector embeddings (using Zep)

### 📁 [004_tier3_business.sql](004_tier3_business.sql) ⭐ **CUSTOMIZED**
**CRM & Sales Features**
- ✅ Transactions/deals (with GHL sync fields)
- ✅ Call events, tags, notes
- ✅ API keys for programmatic access
- ✅ Agent knowledge base (full-text search, **no vectors**)
- ✅ Revenue tracking functions
- ❌ No workflows or integrations table

### 📁 [005_tier4_advanced.sql](005_tier4_advanced.sql) ⭐ **CUSTOMIZED**
**Webhooks & Analytics** (Optional)
- ✅ Webhooks (real-time event notifications)
- ✅ Webhook deliveries (retry mechanism)
- ✅ Agent daily metrics
- ✅ Workspace daily metrics
- ✅ Performance dashboards
- ❌ No workflow executions or workflow integrations

## Migration Recommendations

### Recommended: Tier 1 + Tier 2 (Start Here)

```bash
# Apply in order
psql $DATABASE_URL -f migrations/002_tier1_essential.sql
psql $DATABASE_URL -f migrations/003_tier2_recommended.sql
```

**Why this is perfect for you:**
- ✅ Stores all calls + transcripts
- ✅ AI analysis and sentiment
- ✅ Enhanced appointments (better than basic table)
- ✅ Contacts complement GHL (not replace)
- ✅ Complete audit trail via audit_logs
- ✅ No workflows (FastAPI handles this)
- ✅ No vectors (Zep handles memory)

### Optional: Add Tier 3 (When You Need CRM Features)

```bash
psql $DATABASE_URL -f migrations/004_tier3_business.sql
```

**Add this when:**
- You want to track deals/transactions
- You need detailed call tagging and notes
- You want revenue analytics
- You need API keys for integrations

### Optional: Add Tier 4 (When You Need Webhooks/Analytics)

```bash
psql $DATABASE_URL -f migrations/005_tier4_advanced.sql
```

**Add this when:**
- You need real-time webhooks to external systems
- You want daily performance metrics
- You need analytics dashboards

## Key Differences from Full Schema

Your custom migrations have these changes:

| Feature | Full Schema | Your Custom Schema |
|---------|-------------|-------------------|
| **Workflows** | ✅ DB tables | ❌ Handled in FastAPI |
| **Vector Embeddings** | ✅ pgvector | ❌ Using Zep instead |
| **Appointment History** | ❌ Not included | ✅ Migrated to audit_logs |
| **GHL Integration** | Optional | ✅ Primary CRM (complementary) |
| **Knowledge Base Search** | Vector similarity | Full-text search (pg_trgm) |

## What Gets Migrated

### ✅ Your Existing Data

1. **Tenants** → Enhanced with subscription info
2. **Users** → Enhanced with permissions, status
3. **Appointments** → Enhanced + linked to workspaces, calls, contacts
4. **Appointment History** → **Migrated to audit_logs**

### ✅ Automatic Setup

- Default workspace created for each tenant
- All users added to workspace with appropriate roles
- Existing appointments linked to default workspace
- All appointment history preserved in audit_logs
