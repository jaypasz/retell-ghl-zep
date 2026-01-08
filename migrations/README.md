# Database Migrations

Custom database schema for Retell AI + Zep + GHL voice AI platform.

## Quick Start (Recommended)

```bash
# 1. Apply Tier 1 (Essential)
psql $DATABASE_URL -f migrations/002_tier1_essential.sql

# 2. Apply Tier 2 (Production-Ready)
psql $DATABASE_URL -f migrations/003_tier2_recommended.sql

# 3. Optional: Add business features as needed
psql $DATABASE_URL -f migrations/004_tier3_business.sql

# 4. Optional: Add webhooks & analytics
psql $DATABASE_URL -f migrations/005_tier4_advanced.sql
```

## Migration Files

### ✅ 002_tier1_essential.sql
**What it does:**
- Creates multi-tenant workspace structure
- Sets up voice agents table (Retell AI integration)
- Creates calls and call_transcripts tables
- Creates contacts table (with GHL external_crm_id)
- Migrates your existing tenants, users, appointments

**Required:** Yes

### ✅ 003_tier2_recommended.sql
**What it does:**
- Adds call_analysis (AI sentiment, quality scores)
- Adds call_transcript_segments (turn-by-turn dialogue)
- Adds contact_interactions (all touchpoints)
- Enhances appointments table (status, location, metadata)
- **Migrates appointment_history → audit_logs**
- Creates automatic appointment change tracking
- Creates analytics views

**Required:** Highly recommended for production

### 📦 004_tier3_business.sql
**What it does:**
- Adds transactions table (deals/sales with GHL sync)
- Adds call_events, call_tags, call_notes
- Adds api_keys for programmatic access
- Adds agent_knowledge_base (full-text search, no vectors)
- Includes revenue tracking functions

**Required:** Optional, add when you need CRM features

### 📦 005_tier4_advanced.sql
**What it does:**
- Adds webhooks (real-time event notifications)
- Adds webhook_deliveries (retry mechanism)
- Adds agent_daily_metrics
- Adds workspace_daily_metrics
- Includes analytics calculation functions

**Required:** Optional, add when you need webhooks/dashboards

## Your Configuration

These migrations are customized for your setup:

| Feature | Your Choice | Implementation |
|---------|-------------|----------------|
| **GHL CRM** | ✅ Complement (not replace) | Contacts table has `external_crm_id` field |
| **Workflows** | ❌ No DB tables | Handle in FastAPI (your existing approach) |
| **Appointment History** | ✅ Migrate to audit_logs | Tier 2 includes migration + auto-tracking |
| **Vector Embeddings** | ❌ Using Zep instead | Knowledge base uses full-text search (pg_trgm) |

## What Happens to Your Data

### Tier 1 Migration
```
✅ tenants → Enhanced (adds slug, subscription_tier, settings)
✅ users → Enhanced (adds phone, permissions, status)
✅ appointments → Kept as-is (enhanced in Tier 2)
✅ Creates default workspace for each tenant
✅ Adds all users to their workspace
```

### Tier 2 Migration
```
✅ appointments → Enhanced (adds workspace_id, agent_id, call_id, contact_id, status, etc.)
✅ appointment_history → Migrated to audit_logs
✅ Links appointments to default workspace
✅ Creates automatic audit trail for all future appointment changes
```

## After Migration: Update Your FastAPI App

### 1. Add Supabase Client

```python
# Add to main.py
from supabase import create_client, Client

supabase: Client = create_client(
    os.getenv("SUPABASE_URL"),
    os.getenv("SUPABASE_SERVICE_KEY")
)
```

### 2. Update /retell/inbound Endpoint

```python
@app.post("/retell/inbound")
async def retell_inbound_call(request: RetellInboundRequest):
    # 1. Create/update contact in Supabase
    contact = supabase.table("contacts").upsert({
        "workspace_id": workspace_id,
        "phone": from_number,
        "external_crm_type": "ghl",
        "external_crm_id": ghl_contact_id  # Keep GHL in sync
    }).execute()

    # 2. Create call record
    call = supabase.table("calls").insert({
        "agent_id": agent_id,
        "workspace_id": workspace_id,
        "contact_id": contact.data[0]["id"],
        "retell_call_id": call_id,
        "caller_phone": from_number,
        "direction": "inbound",
        "call_status": "ringing"
    }).execute()

    # 3. Still query Zep for memory (your existing approach)
    memory = await zep_client.get_user_memory(user_id, session_id)

    # 4. Still sync to GHL (your existing approach)
    ghl_contact = await ghl_client.upsert_contact(...)

    # 5. Return dynamic variables
    return {"dynamic_variables": {...}}
```

### 3. Store Call Analysis (New Endpoint)

```python
@app.post("/retell/call-analysis")
async def store_call_analysis(call_data: dict):
    # Store transcript
    supabase.table("call_transcripts").insert({
        "call_id": call_id,
        "full_transcript": transcript
    }).execute()

    # Store analysis
    supabase.table("call_analysis").insert({
        "call_id": call_id,
        "sentiment": sentiment,
        "sentiment_score": score,
        "summary": summary,
        "call_successful": successful
    }).execute()
```

## Testing Migrations

### Before Production

```bash
# 1. Backup your database
pg_dump $DATABASE_URL > backup_$(date +%Y%m%d).sql

# 2. Test in staging first
export DATABASE_URL="your-staging-url"
psql $DATABASE_URL -f migrations/002_tier1_essential.sql
psql $DATABASE_URL -f migrations/003_tier2_recommended.sql

# 3. Verify data
psql $DATABASE_URL -c "SELECT * FROM audit_logs WHERE entity_type = 'appointment' LIMIT 5;"
psql $DATABASE_URL -c "SELECT * FROM workspaces;"
psql $DATABASE_URL -c "SELECT * FROM workspace_members;"
```

## Rollback Plan

If something goes wrong:

```bash
# Restore from backup
psql $DATABASE_URL < backup_YYYYMMDD.sql
```

## Need Help?

See [FEATURE_GUIDE.md](FEATURE_GUIDE.md) for:
- Detailed feature breakdown
- Use case recommendations
- Integration examples
- Cost estimates

## Next Steps

1. ✅ Review this README
2. ✅ Read [FEATURE_GUIDE.md](FEATURE_GUIDE.md)
3. 🔄 Backup your database
4. 🔄 Apply Tier 1 + Tier 2 migrations
5. 🔄 Update your FastAPI app
6. 🔄 Test with a few calls
7. ✨ Add Tier 3/4 as needed
