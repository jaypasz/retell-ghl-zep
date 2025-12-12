# Retell-Zep-GHL Integration API

Railway-ready FastAPI application that integrates Retell AI voice agents with Zep memory and Go High Level CRM.

## Features

- **Retell Inbound Webhook**: Handles incoming calls from Retell AI
- **Zep Memory Integration**: Retrieves customer facts and conversation history
- **GHL Contact Management**: Automatically upserts contacts with call metadata
- **Dynamic Variables**: Returns context-rich variables to Retell agents
- **Call Transcript Storage**: Optionally stores call transcripts back to Zep
- **🆕 Appointment Booking**: Full appointment management with GHL calendars
  - Book new appointments
  - Reschedule existing appointments
  - Cancel appointments
  - Real-time availability checking
  - View customer's existing appointments

## Quick Deploy to Railway

### 1. Deploy to Railway

```bash
# Install Railway CLI
npm i -g @railway/cli

# Login to Railway
railway login

# Initialize project
railway init

# Deploy
railway up
```

### 2. Set Environment Variables

In Railway dashboard, add these variables:

```
ZEP_API_KEY=your_zep_api_key
ZEP_API_URL=https://api.getzep.com
GHL_API_KEY=your_ghl_api_key
GHL_LOCATION_ID=your_ghl_location_id
GHL_CALENDAR_ID=your_ghl_calendar_id
GHL_TIMEZONE=America/New_York
RETELL_API_KEY=your_retell_api_key
```

Railway automatically sets `PORT`.

**To find your GHL Calendar ID:**
1. Go to GHL → Calendars
2. Select your calendar
3. Copy the ID from the URL or settings

### 3. Configure Retell Webhook

In your Retell agent settings, set the webhook URL to:
```
https://your-railway-app.railway.app/retell/inbound
```

## Local Development

### Setup

```bash
# Create virtual environment
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Copy environment file
cp .env.example .env
# Edit .env with your API keys

# Run locally
uvicorn main:app --reload --port 8000
```

### Test Endpoint

```bash
# Health check
curl http://localhost:8000/health

# Test inbound webhook
curl -X POST http://localhost:8000/retell/inbound \
  -H "Content-Type: application/json" \
  -d '{
    "call_id": "test-123",
    "from_number": "+15551234567",
    "to_number": "+15559876543"
  }'
```

## API Endpoints

### `GET /`
Health check endpoint.

**Response:**
```json
{
  "status": "healthy",
  "service": "Retell-Zep-GHL Integration",
  "timestamp": "2024-01-01T00:00:00",
  "integrations": {
    "zep": true,
    "ghl": true
  }
}
```

### `POST /retell/inbound`
Main webhook for Retell inbound calls.

**Request Body:**
```json
{
  "call_id": "abc123",
  "from_number": "+15551234567",
  "to_number": "+15559876543",
  "metadata": {}
}
```

**Response:**
```json
{
  "dynamic_variables": {
    "call_id": "abc123",
    "customer_phone": "+15551234567",
    "customer_known": "yes",
    "customer_summary": "Customer has 3 known facts",
    "customer_facts": ["fact1", "fact2", "fact3"],
    "ghl_contact_id": "contact_xyz",
    "timestamp": "2024-01-01T00:00:00"
  }
}
```

### `POST /retell/call-ended`
Optional webhook for call completion. Stores transcript in Zep.

**Request Body:**
```json
{
  "call_id": "abc123",
  "from_number": "+15551234567",
  "transcript": "Full conversation transcript..."
}
```

### `POST /appointments/book`
Book a new appointment in GHL calendar.

**Request Body:**
```json
{
  "contact_id": "ghl_contact_xyz",
  "slot_time": "2024-01-15T14:00:00Z",
  "title": "Consultation",
  "customer_phone": "+15551234567"
}
```

### `POST /appointments/reschedule`
Reschedule an existing appointment.

**Request Body:**
```json
{
  "event_id": "event_123",
  "new_start_time": "2024-01-16T15:00:00Z"
}
```

### `POST /appointments/cancel`
Cancel an appointment.

**Request Body:**
```json
{
  "event_id": "event_123"
}
```

### `GET /appointments/availability`
Get available appointment slots.

**Query Parameters:**
- `calendar_id` (optional)
- `start_date` (optional, YYYY-MM-DD)
- `end_date` (optional, YYYY-MM-DD)
- `timezone` (optional)

## Integration Flow

```
┌─────────────┐
│   Retell    │
│  Inbound    │
│    Call     │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────┐
│  /retell/inbound Endpoint       │
│                                 │
│  1. Receive call data           │
│  2. Query Zep (user memory)     │
│  3. Upsert GHL (contact)        │
│  4. Return dynamic_variables    │
└─────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────┐
│   Retell Agent                  │
│   (Uses dynamic_variables       │
│    for personalized response)   │
└─────────────────────────────────┘
```

## Using Dynamic Variables in Retell

In your Retell agent prompt, reference the variables:

```
You are a helpful AI receptionist. 

{{#if customer_known === "yes"}}
This is a returning customer. Here's what we know:
{{customer_summary}}

Previous facts:
{{#each customer_facts}}
- {{this}}
{{/each}}
{{else}}
This appears to be a new customer. Be extra welcoming!
{{/if}}

Customer phone: {{customer_phone}}
```

## Zep Integration Details

### User ID Format
- Uses normalized phone number as `user_id`: `5551234567`
- Queries user facts (long-term memory)
- Optionally queries session memory using `call_id`

### Storing Transcripts
The `/retell/call-ended` webhook automatically:
1. Creates a Zep session with `call_id`
2. Links session to user by phone number
3. Stores full transcript for future memory extraction

## GHL Integration Details

### Contact Upsert Logic
1. Searches for existing contact by phone
2. Updates if found, creates if new
3. Adds tags: `retell-inbound`, `voice-ai`
4. Stores custom fields:
   - `last_call_id`
   - `last_call_time`
   - Any metadata from Retell

### Custom Fields
You can extend the GHL data in `main.py`:

```python
ghl_data = {
    "source": "Retell AI Inbound",
    "tags": ["retell-inbound", "voice-ai"],
    "customField": {
        "last_call_id": call_id,
        "last_call_time": datetime.utcnow().isoformat(),
        # Add your custom fields here
        "appointment_requested": "yes",
        "lead_score": 85
    }
}
```

## Error Handling

- All API calls have timeout protection (10-15s)
- Errors are logged but don't stop execution
- If Zep fails, continues with GHL upsert
- If GHL fails, still returns dynamic_variables
- Error details included in response when appropriate

## Monitoring

Check logs in Railway:
```bash
railway logs
```

Key log patterns:
- `"Received Retell inbound call"` - Incoming webhook
- `"Querying Zep for user"` - Memory lookup
- `"Upserting contact to GHL"` - CRM sync
- `"Returning dynamic variables"` - Response sent

## Advanced: Adding More Integrations

To add more data sources, follow this pattern:

```python
# 4. Query your service
if your_client:
    logger.info(f"Querying YourService")
    your_data = await your_client.get_data(user_id)
    dynamic_vars["your_data"] = your_data
    logger.info(f"YourService data retrieved")
```

## Troubleshooting

### "Zep client not configured"
- Verify `ZEP_API_KEY` is set in Railway
- Check `ZEP_API_URL` is correct

### "GHL client not configured"
- Verify both `GHL_API_KEY` and `GHL_LOCATION_ID` are set
- Check API key has correct permissions

### "Contact sync failed"
- Check GHL API key permissions
- Verify location ID is correct
- Review Railway logs for specific error

### Retell not receiving dynamic_variables
- Verify webhook URL in Retell settings
- Test endpoint manually with curl
- Check Railway logs for incoming requests

## Production Checklist

- [ ] Environment variables set in Railway
- [ ] Webhook URL configured in Retell
- [ ] Zep API key has correct permissions
- [ ] GHL API key has contact read/write access
- [ ] Test with real phone call
- [ ] Monitor Railway logs during first calls
- [ ] Verify contacts appear in GHL
- [ ] Confirm Zep memory is being queried
- [ ] Test dynamic_variables in agent responses

## License

MIT
