# Langfuse Integration Guide for Retell Conversation Flow

This guide explains how to set up and use Langfuse with your Retell AI conversation flow for prompt management and observability.

## Overview

The conversation flow configuration integrates Langfuse for:

1. **Prompt Management** - Centralized prompt versioning and A/B testing
2. **Call Tracing** - Full observability of every call
3. **Performance Analytics** - Track success rates, intents, and customer satisfaction
4. **Custom Scoring** - Measure appointment success, AI resolution rates, etc.

## Prerequisites

- Langfuse account (sign up at [https://cloud.langfuse.com](https://cloud.langfuse.com))
- Environment variables configured in `.env`:
  - `LANGFUSE_PUBLIC_KEY`
  - `LANGFUSE_SECRET_KEY`
  - `LANGFUSE_BASE_URL` (defaults to https://cloud.langfuse.com)

## Langfuse Prompt Setup

### 1. Create Prompts in Langfuse Dashboard

Navigate to your Langfuse dashboard and create the following prompts:

#### Prompt: `greeting-new-customer`
```
Hi! Thanks for calling. My name is Sarah, your AI assistant. How can I help you today?
```
**Variables:** None
**Use case:** First-time callers or unknown customers

---

#### Prompt: `greeting-returning-customer`
```
Hi {{customer_name}}! Great to hear from you again. {{#if customer_facts}}I see {{customer_facts[0]}}.{{/if}} How can I help you today?
```
**Variables:**
- `customer_name` - Customer's name from Zep memory
- `customer_facts` - Array of facts from Zep

**Use case:** Returning customers with existing Zep memory

---

#### Prompt: `appointment-confirmation`
```
Perfect! I've successfully booked your appointment for {{selected_slot.formatted}}. You'll receive a confirmation text message with all the details shortly. Is there anything else I can help you with today?
```
**Variables:**
- `selected_slot.formatted` - Human-readable appointment time (e.g., "Monday, January 15 at 02:00 PM")

**Use case:** After successfully booking an appointment

---

#### Prompt: `objection-price`
```
I understand budget is important. The investment really depends on your specific needs. What I'd recommend is scheduling a consultation where we can give you exact pricing based on your situation. Would that work for you?
```
**Variables:** None
**Use case:** When customer expresses price concerns

---

#### Prompt: `faq-hours`
```
We're open Monday through Friday, 9 AM to 5 PM Eastern Time. {{#if after_hours}}We're currently closed, but I can help you schedule something for when we reopen.{{/if}}
```
**Variables:**
- `after_hours` - Boolean indicating if call is outside business hours

**Use case:** When customer asks about business hours

---

### 2. Prompt Versioning

Langfuse supports prompt versioning. To create a new version:

1. Go to the prompt in Langfuse dashboard
2. Click "New Version"
3. Edit the prompt text
4. Save and optionally set as production version

Your FastAPI backend (`main.py:554`) already fetches the latest prompt automatically.

---

## Conversation Flow Integration

### Key Features in `retell_conversation_flow.json`

#### 1. **Langfuse-Powered Nodes**

Nodes that use Langfuse prompts have this structure:

```json
{
  "node_id": "greeting_new",
  "script": "{{langfuse_prompt:greeting-new-customer}}",
  "script_fallback": "Hi! Thanks for calling...",
  "langfuse_metadata": {
    "prompt_name": "greeting-new-customer",
    "track_usage": true
  }
}
```

- `script`: References Langfuse prompt using special syntax
- `script_fallback`: Used if Langfuse is unavailable
- `langfuse_metadata`: Tracks prompt usage and metrics

#### 2. **Intent Classification Tracking**

```json
{
  "node_id": "intent_recognition",
  "langfuse_metadata": {
    "track_intent": true,
    "generation_name": "intent-classification",
    "track_confidence": true
  }
}
```

Automatically logs:
- Detected intent
- Confidence score
- Classification duration

#### 3. **Appointment Success Scoring**

```json
{
  "node_id": "appointment_confirmation",
  "langfuse_score": {
    "name": "appointment_success",
    "value": 1,
    "comment": "Appointment successfully booked"
  }
}
```

Tracks successful appointments for analytics.

#### 4. **Custom Tool Tracking**

All appointment tools (book, reschedule, cancel) include:

```json
{
  "tool_id": "book_appointment",
  "langfuse_tracking": {
    "generation_name": "book-appointment-tool",
    "track_input": true,
    "track_output": true,
    "score_on_success": {
      "name": "tool_success",
      "value": 1
    }
  }
}
```

---

## How It Works

### Call Flow with Langfuse

```
1. Call Starts
   ├─> Create Langfuse Trace (main.py:422)
   │   └─> trace_name: "inbound-call"
   │   └─> user_id: from_number
   │   └─> session_id: call_id
   │
2. Load Customer Context
   ├─> Query Zep for memory
   ├─> Fetch Langfuse prompt based on customer status
   │   └─> Known customer: "greeting-returning-customer"
   │   └─> New customer: "greeting-new-customer"
   │
3. Execute Conversation Flow
   ├─> Log intent classification (generation)
   ├─> Log appointment booking (generation + score)
   ├─> Log any transfers (generation + negative score)
   │
4. Call Ends
   └─> Update Langfuse Trace with:
       ├─> Call duration
       ├─> Outcome
       ├─> Sentiment score
       ├─> Actions completed
       └─> Store transcript in Zep (main.py:580)
```

---

## Backend Integration (Already Implemented)

Your `main.py` already includes Langfuse integration:

### 1. **Trace Creation** (line 422)
```python
trace = create_trace(
    name="inbound-call",
    user_id=from_number,
    session_id=call_id,
    metadata={"from": from_number}
)
```

### 2. **Prompt Fetching** (line 552-566)
```python
prompt_name = "greeting-returning-customer" if customer_known == "yes" else "greeting-new-customer"
prompt_obj = get_prompt(prompt_name, fallback="Hi! Thanks for calling...")
system_prompt_text = getattr(prompt_obj, "prompt", str(prompt_obj))

# Log prompt usage to trace
trace.generation(
    name=f"prompt-{prompt_name}",
    prompt=system_prompt_text,
    metadata={
        "prompt_name": prompt_name,
        "prompt_version": getattr(prompt_obj, "version", None)
    }
)
```

### 3. **Fallback Handling** (langfuse_client.py)
If Langfuse is unavailable:
- Returns fallback prompts
- Creates dummy traces (no-op)
- App continues to function normally

---

## Analytics & Observability

### View in Langfuse Dashboard

1. **Traces Tab** - See all calls with full context:
   - Call duration
   - Customer information
   - Intent detected
   - Actions taken
   - Outcome

2. **Prompts Tab** - Manage and version prompts:
   - Edit prompts without deploying code
   - A/B test different versions
   - Track which version performed best

3. **Generations Tab** - View all AI operations:
   - Intent classifications
   - Tool calls
   - Prompt usage
   - Latency metrics

4. **Scores Tab** - Track success metrics:
   - `appointment_success` - Successful bookings
   - `ai_resolution` - Calls resolved without transfer
   - `tool_success` - Successful API calls

---

## Key Metrics to Track

### Appointment Success Rate
```
appointment_success scores / total calls with booking intent
```

### AI Resolution Rate
```
(total calls - transfer_requested events) / total calls
```

### Average Call Duration
```
Average of call_duration across all traces
```

### Intent Accuracy
```
Track low-confidence intent classifications for retraining
```

---

## Testing the Integration

### 1. Test Inbound Webhook with Langfuse

```bash
curl -X POST http://localhost:8000/retell/inbound \
  -H "Content-Type: application/json" \
  -d '{
    "call_id": "test-123",
    "from_number": "+15551234567",
    "to_number": "+18775550100"
  }'
```

Check Langfuse dashboard for new trace named "inbound-call".

### 2. Test Prompt Fallback

Temporarily set `LANGFUSE_PUBLIC_KEY=""` in `.env` and restart server.

Expected behavior:
- App continues to work
- Uses fallback prompts
- Logs warnings about Langfuse unavailability

---

## Advanced: Custom Scores

You can add custom scores to track specific KPIs:

### Example: Customer Satisfaction Score

In your Retell flow, after call ends:

```json
{
  "langfuse_score": {
    "name": "customer_satisfaction",
    "value": "{{sentiment_score}}",
    "comment": "Based on sentiment analysis"
  }
}
```

### Example: Booking Speed

Track time from intent detection to booking:

```json
{
  "langfuse_score": {
    "name": "booking_speed_seconds",
    "value": "{{time_to_book}}",
    "comment": "Time from intent to confirmation"
  }
}
```

---

## Troubleshooting

### Prompts Not Loading

1. Check environment variables:
   ```bash
   echo $LANGFUSE_PUBLIC_KEY
   echo $LANGFUSE_SECRET_KEY
   ```

2. Check logs for errors:
   ```bash
   railway logs
   ```

3. Verify prompt names match exactly in Langfuse dashboard

### Traces Not Appearing

1. Check Langfuse client initialization (main.py:356)
2. Verify network connectivity to Langfuse
3. Check for exceptions in call processing

### Fallback Prompts Always Used

1. Ensure prompts are published in Langfuse (not just saved as draft)
2. Check prompt names match configuration exactly
3. Verify Langfuse API keys have read permissions

---

## Best Practices

1. **Always Provide Fallbacks** - Ensure app works even if Langfuse is down
2. **Version Prompts Carefully** - Test new versions before setting as production
3. **Use Descriptive Score Names** - Makes analytics easier to understand
4. **Track Key Events** - Intent detection, bookings, transfers, errors
5. **Regular Dashboard Reviews** - Check metrics weekly to identify issues
6. **Iterate on Prompts** - Use Langfuse analytics to improve prompts over time

---

## Environment Variables Summary

Add these to your `.env` file:

```bash
# Langfuse Configuration
LANGFUSE_PUBLIC_KEY=pk-lf-xxx
LANGFUSE_SECRET_KEY=sk-lf-xxx
LANGFUSE_BASE_URL=https://cloud.langfuse.com

# Your existing variables
ZEP_API_KEY=xxx
GHL_API_KEY=xxx
GHL_LOCATION_ID=xxx
GHL_CALENDAR_ID=xxx
RETELL_API_KEY=xxx
```

---

## Next Steps

1. ✅ Set up Langfuse account
2. ✅ Create prompts listed above
3. ✅ Configure environment variables
4. ✅ Import `retell_conversation_flow.json` into Retell
5. ✅ Test with real calls
6. ✅ Monitor Langfuse dashboard
7. ✅ Iterate on prompts based on analytics

---

## Support

- **Langfuse Docs**: https://langfuse.com/docs
- **Retell Docs**: https://docs.retellai.com
- **Your Backend**: See CLAUDE.md for architecture details
