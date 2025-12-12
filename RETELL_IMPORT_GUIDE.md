# Retell AI Conversation Flow Import Guide

This guide walks you through importing and configuring the conversation flow in Retell AI.

## Quick Start

### Step 1: Update Configuration Variables

Before importing, update `retell_conversation_flow.json` with your actual values:

```json
"environment_variables": {
  "BASE_URL": "https://your-app.railway.app",  // ← Your Railway URL
  "company_name": "Your Company Name",         // ← Your business name
  "LANGFUSE_PUBLIC_KEY": "pk-lf-xxx",         // ← From Langfuse dashboard
  "LANGFUSE_SECRET_KEY": "sk-lf-xxx",         // ← From Langfuse dashboard
  "LANGFUSE_BASE_URL": "https://cloud.langfuse.com"
}
```

### Step 2: Import into Retell

1. Log in to [Retell AI Dashboard](https://app.retellai.com)
2. Navigate to **Conversation Flows** section
3. Click **Import Flow** or **Create New Flow**
4. Upload `retell_conversation_flow.json`
5. Verify all nodes imported correctly

### Step 3: Configure Webhooks in Retell

#### A. Inbound Call Webhook
- **URL**: `https://your-app.railway.app/retell/inbound`
- **Method**: POST
- **Trigger**: Call Start
- **Purpose**: Loads customer context from Zep & GHL

#### B. Call Ended Webhook
- **URL**: `https://your-app.railway.app/retell/call-ended`
- **Method**: POST
- **Trigger**: Call End
- **Purpose**: Stores transcript in Zep memory

### Step 4: Set Up Custom Tools

Configure these custom tools in Retell for appointment management:

#### Tool 1: Book Appointment
```json
{
  "name": "book_appointment",
  "description": "Books an appointment for the customer",
  "endpoint": "https://your-app.railway.app/appointments/book",
  "method": "POST",
  "parameters": {
    "contact_id": {
      "type": "string",
      "description": "GHL contact ID",
      "required": false
    },
    "slot_time": {
      "type": "string",
      "description": "ISO 8601 datetime for appointment",
      "required": true
    },
    "title": {
      "type": "string",
      "description": "Appointment title",
      "default": "Phone Appointment"
    },
    "customer_phone": {
      "type": "string",
      "description": "Customer phone number",
      "required": true
    }
  }
}
```

#### Tool 2: Reschedule Appointment
```json
{
  "name": "reschedule_appointment",
  "description": "Reschedules an existing appointment",
  "endpoint": "https://your-app.railway.app/appointments/reschedule",
  "method": "POST",
  "parameters": {
    "event_id": {
      "type": "string",
      "description": "GHL appointment/event ID",
      "required": true
    },
    "new_start_time": {
      "type": "string",
      "description": "New ISO 8601 datetime",
      "required": true
    }
  }
}
```

#### Tool 3: Cancel Appointment
```json
{
  "name": "cancel_appointment",
  "description": "Cancels an appointment",
  "endpoint": "https://your-app.railway.app/appointments/cancel",
  "method": "POST",
  "parameters": {
    "event_id": {
      "type": "string",
      "description": "GHL appointment/event ID to cancel",
      "required": true
    }
  }
}
```

---

## Understanding the Flow Structure

### Main Flow Paths

```
Call Start
  ↓
Webhook (Load Context)
  ↓
Greeting Router
  ├─→ New Customer Greeting
  ├─→ Returning Customer Greeting
  └─→ Returning + Appointment Greeting
  ↓
Intent Recognition
  ├─→ Book Appointment Flow
  ├─→ Reschedule Flow
  ├─→ Cancel Flow
  ├─→ FAQ Handler
  ├─→ Information Gathering
  └─→ Transfer to Human
  ↓
Anything Else?
  ↓
Goodbye / Call End
```

### Dynamic Variables Loaded

The inbound webhook returns these variables for use in conversation:

```json
{
  "call_id": "unique_call_id",
  "customer_phone": "+15551234567",
  "customer_known": "yes" | "no" | "unknown",
  "customer_name": "John Doe",
  "customer_facts": ["Prefers morning appointments", "Interested in enterprise plan"],
  "ghl_contact_id": "contact_xyz123",
  "available_slots": [
    {
      "datetime": "2024-01-15T14:00:00Z",
      "formatted": "Monday, January 15 at 02:00 PM",
      "date": "2024-01-15",
      "time": "02:00 PM"
    }
  ],
  "has_availability": true,
  "slots_count": 5,
  "existing_appointments": [...],
  "has_existing_appointments": false,
  "appointment_count": 0
}
```

---

## Customization Guide

### 1. Modify Greetings

Edit these nodes in the JSON:
- `greeting_new` - New customer greeting
- `greeting_returning` - Returning customer greeting
- `greeting_returning_with_appointment` - Customer with existing appointment

Or better yet, **use Langfuse** to manage prompts without redeploying!

### 2. Add Custom Intents

In `intent_recognition` node, add to `intents` array:

```json
{
  "intents": [
    "book_appointment",
    "reschedule_appointment",
    "cancel_appointment",
    "ask_question",
    "request_information",
    "speak_to_human",
    "general_inquiry",
    "check_order_status",     // ← New intent
    "request_refund"          // ← New intent
  ]
}
```

Then add routing in `next_nodes`:

```json
{
  "next_nodes": {
    "check_order_status": "order_status_node",
    "request_refund": "refund_flow_node"
  }
}
```

### 3. Customize FAQ Responses

Edit the `faq_handler` node's `knowledge_base`:

```json
{
  "knowledge_base": [
    {
      "question": "your custom question",
      "answer": "Your custom answer here",
      "keywords": ["keyword1", "keyword2"]
    }
  ]
}
```

### 4. Change Transfer Behavior

Edit `transfer_to_human` node:

```json
{
  "transfer_config": {
    "department": "sales",           // or "support", "billing", etc.
    "transfer_type": "warm",         // or "cold"
    "phone_number": "+18005551234"   // Your transfer number
  }
}
```

---

## Testing Checklist

### Before Going Live

- [ ] Test inbound webhook responds correctly
- [ ] Verify Zep memory loads for known customers
- [ ] Confirm GHL contact upsert works
- [ ] Test calendar availability fetching
- [ ] Test appointment booking flow end-to-end
- [ ] Test reschedule flow
- [ ] Test cancellation flow
- [ ] Verify call-ended webhook stores transcript
- [ ] Test transfer to human functionality
- [ ] Check Langfuse traces are being created
- [ ] Verify fallback prompts work if Langfuse is down

### Test Calls

#### Test 1: New Customer Booking
1. Call with unknown number
2. Should hear new customer greeting
3. Express interest in booking
4. Provide name when asked
5. Select time slot
6. Confirm booking
7. Verify appointment created in GHL

#### Test 2: Returning Customer
1. Call with known number (in Zep)
2. Should hear personalized greeting with facts
3. Should see existing appointments if any
4. Test any flow (FAQ, booking, etc.)

#### Test 3: Reschedule
1. Call with number that has appointment
2. Ask to reschedule
3. Should confirm existing appointment time
4. Select new time
5. Verify appointment updated in GHL

#### Test 4: Transfer
1. Call and ask for human
2. Should transfer smoothly
3. Human should receive context

---

## Monitoring & Analytics

### Check These Regularly

1. **Retell Dashboard**
   - Call volume
   - Call duration
   - Success rates

2. **Langfuse Dashboard**
   - Trace completion rates
   - Prompt performance
   - Intent accuracy
   - Appointment success rate

3. **Railway Logs**
   ```bash
   railway logs
   ```
   - API errors
   - Integration failures
   - Webhook issues

4. **GHL Dashboard**
   - Appointment bookings
   - Contact creation
   - Tag accuracy

---

## Common Issues & Solutions

### Issue: Dynamic Variables Not Loading

**Symptom**: Agent doesn't have customer context

**Solution**:
1. Check webhook URL is correct in Retell
2. Verify Railway app is running: `railway status`
3. Check logs for errors: `railway logs`
4. Test webhook manually:
   ```bash
   curl -X POST https://your-app.railway.app/retell/inbound \
     -H "Content-Type: application/json" \
     -d '{"call_id":"test","from_number":"+15551234567","to_number":"+18005551234"}'
   ```

### Issue: Appointments Not Booking

**Symptom**: Tool call fails or returns error

**Solution**:
1. Verify `GHL_CALENDAR_ID` is set in environment
2. Check GHL API key has calendar permissions
3. Test endpoint directly:
   ```bash
   curl -X POST https://your-app.railway.app/appointments/book \
     -H "Content-Type: application/json" \
     -d '{
       "customer_phone": "+15551234567",
       "slot_time": "2024-01-15T14:00:00Z",
       "title": "Test Appointment"
     }'
   ```

### Issue: Langfuse Prompts Not Loading

**Symptom**: Using fallback prompts instead of Langfuse versions

**Solution**:
1. Verify prompts are published (not draft) in Langfuse
2. Check prompt names match exactly
3. Verify `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` are set
4. Check logs for Langfuse connection errors

### Issue: Call Transcript Not Saved

**Symptom**: No transcript in Zep after call

**Solution**:
1. Verify call-ended webhook is configured
2. Check `ZEP_API_KEY` is valid
3. Check logs for Zep API errors
4. Verify session creation permissions in Zep

---

## Production Deployment Checklist

### Environment Variables (Railway)
```bash
# Required
ZEP_API_KEY=xxx
GHL_API_KEY=xxx
GHL_LOCATION_ID=xxx
GHL_CALENDAR_ID=xxx
RETELL_API_KEY=xxx

# Langfuse (Optional but Recommended)
LANGFUSE_PUBLIC_KEY=pk-lf-xxx
LANGFUSE_SECRET_KEY=sk-lf-xxx
LANGFUSE_BASE_URL=https://cloud.langfuse.com

# Optional
GHL_TIMEZONE=America/New_York
ZEP_API_URL=https://api.getzep.com
```

### Security
- [ ] All API keys are secure and not exposed
- [ ] Webhook URLs use HTTPS
- [ ] Rate limiting configured
- [ ] Error messages don't leak sensitive info

### Monitoring
- [ ] Railway monitoring enabled
- [ ] Langfuse dashboard set up
- [ ] Error alerting configured
- [ ] Log retention configured

### Documentation
- [ ] Team trained on flow
- [ ] Escalation procedures documented
- [ ] Common issues documented
- [ ] Contact info for support

---

## Support Resources

- **Retell AI Docs**: https://docs.retellai.com
- **Langfuse Docs**: https://langfuse.com/docs
- **Zep Docs**: https://docs.getzep.com
- **GHL API Docs**: https://highlevel.stoplight.io
- **Your Backend Docs**: See `CLAUDE.md` in this repo

---

## Advanced: A/B Testing Prompts

Use Langfuse to A/B test different greeting styles:

1. Create two versions of `greeting-new-customer` prompt
2. Set both to "Production" with 50/50 split
3. Langfuse will randomly serve each version
4. After 100+ calls, check which performed better
5. Set winning version to 100%

Metrics to compare:
- Average call duration
- Intent detection speed
- Appointment booking rate
- Customer satisfaction (sentiment)

---

## Conclusion

Your conversation flow is now ready to import into Retell! The integration with Zep, GHL, and Langfuse provides a powerful foundation for personalized, data-driven customer interactions.

Remember:
- **Test thoroughly** before going live
- **Monitor regularly** for issues
- **Iterate on prompts** based on data
- **Keep documentation updated** as you customize

Good luck! 🚀
