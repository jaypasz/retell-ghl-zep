# Retell AI Conversation Flow Setup Guide

This guide explains how to import and configure the Retell AI conversation flow for your appointment booking system.

## Files Overview

- **retell_conversation_flow_v2.json** - The NEW Retell AI compatible conversation flow
- **retell_conversation_flow.json** - The OLD custom format (not compatible with Retell)

## Pre-Import Checklist

Before importing the conversation flow, ensure you have:

### 1. Backend Endpoints Ready

Your FastAPI backend must have these endpoints running:

✅ **POST /retell/inbound** - Returns dynamic variables
```json
{
  "dynamic_variables": {
    "call_id": "string",
    "customer_phone": "string",
    "customer_known": "yes|no|unknown",
    "customer_name": "string",
    "ghl_contact_id": "string",
    "available_slots_count": "3",
    "existing_appointments_count": "0",
    "first_available_slot": "Monday, January 15 at 02:00 PM",
    "existing_appointment_time": "Tuesday, January 16 at 10:00 AM"
  }
}
```

✅ **POST /appointments/book** - Creates appointment
```json
{
  "phone": "+15551234567",
  "slot_time": "2024-01-15T14:00:00Z",
  "customer_name": "John Doe",
  "title": "Appointment with John Doe",
  "appointment_data": {
    "call_id": "call_abc123"
  }
}
```

✅ **DELETE /appointments/cancel** - Cancels appointment
```json
{
  "event_id": "event_xyz789"
}
```

✅ **POST /appointments/reschedule** - Reschedules appointment
```json
{
  "event_id": "event_xyz789",
  "new_start_time": "2024-01-16T15:00:00Z"
}
```

### 2. Environment Variables

You need to set `BASE_URL` in Retell AI dashboard or replace `{{BASE_URL}}` in the JSON with your actual Railway URL:

```
https://your-app.railway.app
```

### 3. Dynamic Variables Update Required

The flow expects these dynamic variables from your `/retell/inbound` webhook. **Update your [main.py](main.py:423-593) endpoint** to return:

```python
# In /retell/inbound endpoint, around line 550-590
dynamic_variables = {
    "call_id": call_id,
    "customer_phone": from_number,
    "customer_known": "yes" if user_memory else "no",
    "customer_name": "",  # Extract from user_memory if available
    "ghl_contact_id": ghl_contact_id or "",
    "available_slots_count": str(len(available_slots)),  # MUST BE STRING
    "existing_appointments_count": str(len(existing_appointments)),  # MUST BE STRING
    "first_available_slot": available_slots[0]["formatted"] if available_slots else "",
    "existing_appointment_time": existing_appointments[0]["formatted"] if existing_appointments else ""
}
```

**CRITICAL:** All values MUST be strings (not numbers or booleans).

## Import Methods

### Method 1: Via Retell AI Dashboard (Recommended)

1. Log in to [dashboard.retellai.com](https://dashboard.retellai.com)
2. Navigate to **Conversation Flows** or **Agents**
3. Click **Create New** or **Import**
4. Upload `retell_conversation_flow_v2.json`
5. Configure environment variables in the dashboard
6. Test the flow using Retell's testing interface

### Method 2: Via Retell AI API

```bash
curl -X POST https://api.retellai.com/v2/create-conversation-flow \
  -H "Authorization: Bearer YOUR_RETELL_API_KEY" \
  -H "Content-Type: application/json" \
  -d @retell_conversation_flow_v2.json
```

Response will include a `flow_id` that you can use in your agent configuration.

## Post-Import Configuration

### 1. Configure Webhook in Retell Dashboard

Set your inbound webhook URL to:
```
https://your-app.railway.app/retell/inbound
```

### 2. Update Custom Function URLs

In the Retell dashboard, ensure all custom functions point to your Railway deployment:
- `book_appointment` → `https://your-app.railway.app/appointments/book`
- `cancel_appointment` → `https://your-app.railway.app/appointments/cancel`
- `reschedule_appointment` → `https://your-app.railway.app/appointments/reschedule`

### 3. Test Dynamic Variables

Test that your webhook returns proper format:

```bash
curl -X POST https://your-app.railway.app/retell/inbound \
  -H "Content-Type: application/json" \
  -d '{
    "call_id": "test_call_123",
    "from_number": "+15551234567",
    "to_number": "+15559876543"
  }'
```

Expected response structure:
```json
{
  "dynamic_variables": {
    "available_slots_count": "3",  // String, not number
    "existing_appointments_count": "1",  // String, not number
    // ... other variables
  }
}
```

### 4. Configure Call Transfer (Optional)

If you want to enable human transfer functionality:
1. In Retell dashboard, configure transfer numbers
2. Update the `transfer_to_human` node settings
3. Test transfer flow

## Key Differences from Original Flow

### What Changed

| Original (v1) | New (v2) | Reason |
|--------------|----------|---------|
| Custom node types (`speak`, `branch`, etc.) | All `conversation` nodes | Retell only supports specific node types |
| `next_node` field | `edges` array with conditions | Retell's required structure |
| JavaScript conditions (`===`, `&&`) | Natural language prompts | Retell uses LLM-based transitions |
| Langfuse metadata in nodes | Removed | Not part of Retell schema (handle server-side) |
| FAQ knowledge base arrays | Conversation instructions | Retell doesn't have FAQ node type |
| Intent classifier node | Conversation node with intent logic | Retell handles via LLM prompts |

### What Was Preserved

✅ Complete appointment booking flow
✅ Reschedule and cancel functionality
✅ Customer greeting personalization
✅ Dynamic variable usage
✅ Webhook integrations
✅ Error handling and transfers
✅ Natural conversation flow

### What Was Removed (Handle Separately)

❌ Langfuse integration metadata - Implement in your backend
❌ Detailed analytics tracking - Use Retell's built-in analytics + your backend
❌ Structured FAQ knowledge base - Now handled via conversational prompts
❌ Confidence thresholds - Retell manages this automatically

## Testing the Flow

### Test Scenarios

1. **New Customer Booking**
   - Call with unknown phone number
   - Should greet generically
   - Should ask for name
   - Should present available slots
   - Should book appointment

2. **Returning Customer**
   - Call with known phone number
   - Should greet by name
   - Should mention existing appointments if any
   - Should handle booking/rescheduling

3. **Reschedule Flow**
   - Customer says "I need to reschedule"
   - Should confirm existing appointment
   - Should present new slots
   - Should update appointment

4. **Cancel Flow**
   - Customer says "I need to cancel"
   - Should confirm appointment to cancel
   - Should ask for confirmation
   - Should process cancellation

5. **FAQ Handling**
   - Ask about hours, location, pricing
   - Should provide appropriate answers
   - Should offer to book consultation

6. **Error Scenarios**
   - No availability (slots_count = 0)
   - Booking API failure
   - Transfer to human

### Debug Tips

If the flow doesn't work as expected:

1. **Check webhook response format** - All dynamic variables must be strings
2. **Verify BASE_URL** - Must be your actual Railway URL
3. **Test custom functions** - Each endpoint should work standalone
4. **Review Retell logs** - Dashboard shows detailed execution logs
5. **Validate JSON** - Use [jsonlint.com](https://jsonlint.com) to check syntax

## Advanced Customization

### Modify Greeting Prompts

Edit the `greeting` node's instruction text in [retell_conversation_flow_v2.json](retell_conversation_flow_v2.json:26-35).

### Add More Slots to Present

Update the `check_availability` node to present more or fewer time slots:
```json
"text": "...present the first 3-4 available slots..."
```

### Change Voice Settings

Add to `global_settings` (not in v2, but supported by Retell):
```json
"voice": {
  "voice_id": "your_voice_id",
  "speed": 1.0,
  "stability": 0.5
}
```

### Add Business Hours Check

Create a new conversation node that checks time of day before presenting availability.

## Troubleshooting

### "Invalid JSON schema" Error
- Ensure all `tools` have `"type": "object"` at root of parameters
- Validate JSON syntax

### "Unknown node type" Error
- Check that all nodes use `"type": "conversation"` or `"type": "function"`
- Remove any custom node types

### Dynamic Variables Not Showing
- Verify webhook returns `dynamic_variables` key
- Ensure all values are strings (not numbers/booleans)
- Check webhook is configured in Retell dashboard

### Functions Not Executing
- Verify endpoint URLs are correct and accessible
- Check that parameters match expected format
- Review Retell function execution logs

### Transitions Not Working
- Ensure `edges` array has proper `transition_condition` objects
- Check that destination node IDs exist
- Review Retell execution trace for transition decisions

## Support

- **Retell AI Docs:** [docs.retellai.com](https://docs.retellai.com)
- **API Reference:** [docs.retellai.com/api-references](https://docs.retellai.com/api-references)
- **Your Backend:** Check Railway logs for webhook/function errors

## Next Steps

1. ✅ Import `retell_conversation_flow_v2.json` to Retell dashboard
2. ✅ Update your [main.py](main.py:550-590) to return proper dynamic variables format
3. ✅ Configure BASE_URL environment variable
4. ✅ Test with a live call
5. ✅ Monitor Retell dashboard logs
6. ✅ Iterate based on real conversation feedback
