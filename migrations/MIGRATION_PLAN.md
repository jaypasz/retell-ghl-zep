# Migration Plan: Remote Schema → Voice AI Platform

## 🎯 Recommended Migration Path

Based on your current setup (Retell + Zep + GHL + FastAPI), here's the recommended path:

### **Path: Tier 1 + Tier 2 + Hybrid Appointments**

**Why this combination:**
- ✅ All essential voice agent features
- ✅ Call analysis and quality tracking
- ✅ Preserves your unique `appointment_history` table
- ✅ Adds comprehensive CRM contacts (can replace GHL)
- ✅ Audit trail for compliance
- ❌ Skips workflows (use FastAPI instead)
- ❌ Skips metrics tables (can add later)

**Estimated Storage:** ~200MB per 1,000 calls/month
**Supabase Tier:** Free tier is fine for 6+ months

---

## 📋 Pre-Migration Checklist

- [ ] **Backup your database** (use Supabase dashboard or `pg_dump`)
- [ ] **Test in staging/dev first** (create a new Supabase project)
- [ ] **Review your current data**:
  - 1 tenant
  - 2 users
  - 0 appointments (safe to modify schema)
  - No critical data at risk
- [ ] **Check Supabase extensions**:
  - `uuid-ossp` ✅ (already enabled)
  - `pg_trgm` ⚠️ (needed for full-text search - will enable)
  - `pgvector` ❌ (optional - only if you want RAG/embeddings)
- [ ] **Update environment variables** (see below)
- [ ] **Plan app code updates** (see integration guide)

---

## 🚀 Migration Steps

### Step 1: Run Tier 1 Migration (Essential Tables)

**File:** `002_tier1_essential.sql`

**What it does:**
- Upgrades `tenants` table (adds slug, subscription fields)
- Upgrades `users` table (renames encrypted_password → password_hash)
- Creates `workspaces` and `workspace_members` tables
- Creates `voice_agents` and `agent_phone_numbers` tables
- Creates `contacts` table
- Creates `calls` and `call_transcripts` tables
- Creates default workspace for your tenant
- Adds your users to the default workspace

**Run via Supabase:**
```bash
# Option A: Supabase Dashboard
# 1. Go to SQL Editor
# 2. Paste contents of 002_tier1_essential.sql
# 3. Click "Run"

# Option B: Supabase CLI
supabase db push
```

**Validation:**
```sql
-- Check new tables exist
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;

-- Should see:
-- agent_phone_numbers
-- call_transcripts
-- calls
-- contacts
-- voice_agents
-- workspace_members
-- workspaces
-- (plus your existing tables)

-- Check workspace created
SELECT * FROM workspaces;

-- Check users added to workspace
SELECT * FROM workspace_members;
```

---

### Step 2: Run Tier 2 Migration (Recommended Features)

**Create file:** `003_tier2_recommended.sql`

**What it includes:**
- `call_analysis` - AI sentiment/quality analysis
- `call_transcript_segments` - Turn-by-turn conversation
- `contact_interactions` - Track all touchpoints
- `audit_logs` - System audit trail
- Enhanced `appointments` table (more fields)

**Contents:**

```sql
-- See next migration file (I'll create this if you want)
```

---

### Step 3: Run Hybrid Migration (Preserve appointment_history)

**File:** `006_hybrid_keep_appointment_history.sql`

**What it does:**
- Adds comprehensive fields to your existing `appointments` table
- Keeps your unique `appointment_history` table
- Links appointments to workspaces and contacts
- Populates new fields from existing data
- Creates helpful view: `appointments_with_history`
- Maintains backward compatibility

**Validation:**
```sql
-- Check appointments upgraded
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'appointments'
ORDER BY ordinal_position;

-- Check appointment_history still exists
SELECT * FROM appointment_history LIMIT 1;

-- Check new view
SELECT * FROM appointments_with_history;
```

---

## 🔧 Post-Migration: Update Your FastAPI App

### 1. Install Supabase Python Client

```bash
pip install supabase
pip freeze > requirements.txt
```

### 2. Update `.env`

```bash
# Add to your existing .env file
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_KEY=your-anon-key
SUPABASE_SERVICE_KEY=your-service-role-key
```

### 3. Create Database Client (add to `main.py`)

```python
from supabase import create_client, Client

# Add after existing clients (ZepClient, GHLClient)
class SupabaseDB:
    def __init__(self):
        url = os.getenv("SUPABASE_URL")
        key = os.getenv("SUPABASE_SERVICE_KEY")
        if not url or not key:
            logger.warning("Supabase credentials not configured")
            self.client = None
        else:
            self.client = create_client(url, key)

    async def upsert_contact(self, workspace_id: str, phone: str, data: dict):
        """Upsert contact by phone number"""
        if not self.client:
            return None

        # Search for existing contact
        result = self.client.table("contacts").select("id").eq("workspace_id", workspace_id).eq("phone", phone).execute()

        if result.data:
            # Update existing
            contact_id = result.data[0]["id"]
            self.client.table("contacts").update(data).eq("id", contact_id).execute()
            return contact_id
        else:
            # Create new
            data["workspace_id"] = workspace_id
            data["phone"] = phone
            result = self.client.table("contacts").insert(data).execute()
            return result.data[0]["id"] if result.data else None

    async def create_call(self, call_data: dict):
        """Create a call record"""
        if not self.client:
            return None
        result = self.client.table("calls").insert(call_data).execute()
        return result.data[0] if result.data else None

    async def save_transcript(self, call_id: str, transcript: str):
        """Save call transcript"""
        if not self.client:
            return
        self.client.table("call_transcripts").insert({
            "call_id": call_id,
            "full_transcript": transcript
        }).execute()

# Initialize
db = SupabaseDB()
```

### 4. Update `/retell/inbound` Endpoint

```python
@app.post("/retell/inbound")
async def retell_inbound_call(request: RetellInboundRequest):
    call_id = request.call_id
    from_number = request.from_number
    to_number = request.to_number

    logger.info(f"Inbound call: {call_id} from {from_number}")

    # Get workspace ID (for now, use the default workspace)
    # TODO: Implement proper workspace routing based on to_number
    workspace_result = db.client.table("workspaces").select("id").eq("slug", "default").execute()
    workspace_id = workspace_result.data[0]["id"] if workspace_result.data else None

    # 1. Upsert contact in Supabase
    normalized_phone = from_number.replace("+", "").replace("-", "").replace(" ", "")
    contact_id = await db.upsert_contact(
        workspace_id=workspace_id,
        phone=from_number,
        data={
            "phone": from_number,
            "tags": ["retell-inbound"],
            "custom_fields": {"last_call_id": call_id}
        }
    )

    # 2. Create call record
    call_record_id = await db.create_call({
        "workspace_id": workspace_id,
        "contact_id": contact_id,
        "retell_call_id": call_id,
        "caller_phone": from_number,
        "direction": "inbound",
        "call_status": "in-progress",
        "started_at": datetime.utcnow().isoformat(),
        "metadata": {"to_number": to_number}
    })

    # 3. Get Zep memory (still useful for conversation context)
    zep_memory = await zep_client.get_user_memory(normalized_phone, call_id)

    # 4. (Optional) Still sync to GHL if you want
    if ghl_client:
        ghl_result = await ghl_client.upsert_contact(from_number, {
            "phone": from_number,
            "tags": ["retell-inbound"],
            "customField": {"last_call_id": call_id}
        })

    # 5. Return dynamic variables
    return {
        "dynamic_variables": {
            "call_id": call_id,
            "customer_phone": from_number,
            "contact_id": contact_id,
            "customer_known": "yes" if zep_memory.get("facts") else "no",
            "customer_facts": zep_memory.get("facts", [])
        }
    }
```

### 5. Update `/retell/call-ended` Endpoint

```python
@app.post("/retell/call-ended")
async def retell_call_ended(request: RetellCallEndedRequest):
    call_id = request.call_id
    transcript = request.transcript

    logger.info(f"Call ended: {call_id}")

    # Update call record in Supabase
    if db.client:
        db.client.table("calls").update({
            "call_status": "completed",
            "ended_at": datetime.utcnow().isoformat(),
            "duration_seconds": request.duration_seconds if hasattr(request, 'duration_seconds') else None
        }).eq("retell_call_id", call_id).execute()

        # Save transcript
        call_result = db.client.table("calls").select("id").eq("retell_call_id", call_id).execute()
        if call_result.data:
            internal_call_id = call_result.data[0]["id"]
            await db.save_transcript(internal_call_id, transcript)

    # Still store in Zep if you want
    if zep_client:
        # ... existing Zep code

    return {"status": "success"}
```

---

## 🧪 Testing Plan

### Phase 1: Schema Testing (Day 1)

1. Run migrations in order on staging
2. Verify all tables created
3. Check foreign keys working
4. Test sample data insertion

### Phase 2: App Integration Testing (Day 2-3)

1. Update FastAPI code
2. Test `/retell/inbound` endpoint
3. Test contact creation
4. Test call record creation
5. Test transcript storage

### Phase 3: End-to-End Testing (Day 4-5)

1. Make test calls via Retell
2. Verify data flows correctly
3. Check Supabase dashboard for data
4. Test appointment booking
5. Verify appointment_history logging

### Phase 4: Production Migration (Day 6)

1. Schedule maintenance window (optional - no downtime needed)
2. Backup production database
3. Run migrations on production
4. Deploy updated FastAPI app
5. Monitor logs for 24 hours

---

## 🔄 Rollback Plan

If anything goes wrong:

### Option 1: Database Rollback

```sql
-- Drop new tables (in reverse order)
DROP VIEW IF EXISTS appointments_with_history CASCADE;
DROP TABLE IF EXISTS audit_logs CASCADE;
DROP TABLE IF EXISTS contact_interactions CASCADE;
DROP TABLE IF EXISTS call_transcripts CASCADE;
DROP TABLE IF EXISTS calls CASCADE;
DROP TABLE IF EXISTS contacts CASCADE;
DROP TABLE IF EXISTS agent_phone_numbers CASCADE;
DROP TABLE IF EXISTS voice_agents CASCADE;
DROP TABLE IF EXISTS workspace_members CASCADE;
DROP TABLE IF EXISTS workspaces CASCADE;

-- Restore original appointments columns (if modified)
-- This is trickier - better to restore from backup

-- Restore users.password_hash → users.encrypted_password
ALTER TABLE users RENAME COLUMN password_hash TO encrypted_password;
```

### Option 2: Restore from Backup

```bash
# Restore full database from Supabase backup
# (Use Supabase dashboard: Database → Backups)
```

---

## 📊 Success Metrics

After migration, verify:

- [ ] All Retell calls create records in `calls` table
- [ ] Transcripts saved to `call_transcripts` table
- [ ] Contacts auto-created from phone numbers
- [ ] Appointments still booking correctly
- [ ] `appointment_history` still logging changes
- [ ] No errors in application logs
- [ ] Supabase query performance <100ms
- [ ] RLS policies working (if enabled)

---

## 🆘 Troubleshooting

### Issue: Migration fails with "relation already exists"

**Fix:** Migrations use `CREATE TABLE IF NOT EXISTS` - safe to re-run

### Issue: Foreign key constraint violation

**Fix:** Run migrations in order (Tier 1 → Tier 2 → Hybrid)

### Issue: Can't link appointments to workspace

**Fix:** Make sure Tier 1 created workspaces first:

```sql
SELECT * FROM workspaces;
-- If empty, run Tier 1 migration again
```

### Issue: Supabase client not connecting

**Fix:** Check environment variables:

```python
import os
print(os.getenv("SUPABASE_URL"))
print(os.getenv("SUPABASE_SERVICE_KEY"))
```

---

## 📈 Next Steps After Migration

1. **Enable Row Level Security (RLS)**
   - Secure your data per workspace
   - See Supabase docs on RLS

2. **Add Call Analysis**
   - Integrate OpenAI/Anthropic for sentiment analysis
   - Populate `call_analysis` table after each call

3. **Build Admin Dashboard**
   - Use Supabase Dashboard or build custom UI
   - Show calls, contacts, appointments

4. **Phase Out GHL (Optional)**
   - Gradually migrate CRM to Supabase `contacts`
   - Keep GHL for calendars initially

5. **Add Workflow System**
   - Tier 4 migration for advanced automation

---

## 💰 Cost Estimate

**Current (Free Tier):**
- 500MB database
- 2GB bandwidth/month
- No cost

**After Migration (1,000 calls/month):**
- ~200MB database usage
- ~5GB bandwidth/month
- **Still free tier** ✅

**Scale to 10,000 calls/month:**
- ~2GB database usage
- ~50GB bandwidth/month
- **Need Pro ($25/month)** ⚠️

---

## 🎉 Benefits After Migration

| Before | After |
|--------|-------|
| GHL CRM (external dependency) | Own your contact data |
| No call history tracking | Full call records + transcripts |
| Basic appointments | Rich appointment system |
| No audit trail | Full change history |
| Zep-only memory | Database + Zep hybrid |
| Manual reporting | Analytics ready |
| Single workspace | Multi-workspace ready |

---

## 📞 Ready to Migrate?

**Recommended:** Start with staging/dev environment

```bash
# 1. Create new Supabase project for testing
# 2. Run migrations in SQL Editor
# 3. Test your FastAPI app locally
# 4. Make test calls
# 5. Verify data
# 6. Then migrate production
```

**Questions? Next steps?**

Let me know:
1. Do you want me to create the Tier 2 migration file?
2. Do you want me to create a complete FastAPI integration guide?
3. Do you want me to help set up RLS policies?
4. Any specific concerns about the migration?
