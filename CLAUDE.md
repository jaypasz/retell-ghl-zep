# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FastAPI application that integrates Retell AI voice agents with Zep memory and Go High Level (GHL) CRM. The app handles inbound call webhooks from Retell, enriches them with customer memory from Zep, syncs contacts to GHL, and manages appointment bookings through GHL calendars.

## Development Commands

### Local Development
```bash
# Setup environment
python -m venv venv
source venv/bin/activate  # Windows: venv\Scripts\activate
pip install -r requirements.txt
cp env.example .env  # Then edit .env with your API keys

# Run server locally
uvicorn main:app --reload --port 8000

# Run test suite
python test_endpoint.py  # Requires server running on localhost:8000
```

### Deployment (Railway)
```bash
railway login
railway init
railway up
```

## Architecture

### Core Integration Flow

1. **Retell Inbound Webhook** (`/retell/inbound`) - Main entry point
   - Receives call data from Retell AI (call_id, from_number, to_number)
   - Queries Zep for customer memory using phone number as user_id
   - Upserts contact to GHL with call metadata and tags
   - Fetches GHL calendar availability and existing appointments
   - Returns `dynamic_variables` dict to Retell agent for personalized context

2. **Zep Memory System** (`ZepClient` class in main.py:48-97)
   - User ID: normalized phone number (e.g., "5551234567")
   - Session ID: Retell call_id
   - Retrieves user facts (long-term memory) and session memory
   - Stores call transcripts via `/retell/call-ended` webhook

3. **GHL Contact Management** (`GHLClient` class in main.py:101-331)
   - Contact upsert: searches by phone, updates if exists, creates if new
   - Auto-tags: "retell-inbound", "voice-ai"
   - Custom fields: last_call_id, last_call_time, plus any Retell metadata
   - Calendar operations: get slots, book/reschedule/cancel appointments

4. **Appointment System** (lines 606-816)
   - `/appointments/book`: Creates appointment, can auto-create contact from phone
   - `/appointments/reschedule`: Updates appointment start time
   - `/appointments/cancel`: Deletes appointment
   - `/appointments/availability`: Returns available slots for date range
   - All appointment endpoints use GHL_CALENDAR_ID from environment

### Client Classes

**ZepClient** (main.py:48-97):
- `get_user_memory(user_id, session_id)`: Fetches user facts and session memory
- Returns 404-safe empty response if user not found
- Uses Zep API v2 endpoints

**GHLClient** (main.py:101-331):
- `upsert_contact(phone, data)`: Search-then-update-or-create pattern
- `get_available_slots(calendar_id, start_date, end_date, timezone)`: Fetches free calendar slots
- `book_appointment(calendar_id, contact_id, slot_time, appointment_data)`: Creates appointment
- `reschedule_appointment(event_id, new_start_time)`: Updates appointment time
- `cancel_appointment(event_id)`: Deletes appointment
- `get_contact_appointments(contact_id)`: Lists contact's appointments
- All methods use async httpx with 10-15s timeouts
- GHL API base URL: `https://services.leadconnectorhq.com`
- Requires header: `Version: 2021-07-28`

### Environment Configuration

Required environment variables (see env.example):
- **Zep**: `ZEP_API_KEY`, `ZEP_API_URL` (defaults to https://api.getzep.com)
- **GHL**: `GHL_API_KEY`, `GHL_LOCATION_ID`, `GHL_CALENDAR_ID` (optional for appointments), `GHL_TIMEZONE` (defaults to America/New_York)
- **Retell**: `RETELL_API_KEY`
- **Server**: `PORT` (Railway sets automatically, defaults to 8000)

Missing API keys result in graceful degradation - clients won't initialize but app continues.

## Code Patterns

### Phone Number Normalization
Always normalize phone numbers for user_id and contact lookups:
```python
user_id = from_number.replace("+", "").replace("-", "").replace(" ", "")
```

### Error Handling Pattern
All external API calls follow this pattern:
- Wrap in try/except with httpx.HTTPStatusError and general Exception
- Log errors with logger.error()
- Return dict with "error" key on failure
- Don't raise exceptions - allow flow to continue
- Example: Zep failure doesn't prevent GHL upsert

### Dynamic Variables Response
The `/retell/inbound` endpoint must return this structure:
```json
{
  "dynamic_variables": {
    "call_id": "...",
    "customer_phone": "...",
    "customer_known": "yes|no|unknown",
    "customer_facts": [...],
    "ghl_contact_id": "...",
    "available_slots": [...],
    "existing_appointments": [...]
  }
}
```

### Appointment Slot Formatting
Available slots are formatted for Retell agents (main.py:465-478):
```python
{
  "datetime": "ISO8601 string",
  "formatted": "Monday, January 15 at 02:00 PM",
  "date": "2024-01-15",
  "time": "02:00 PM"
}
```

## Testing

Use `test_endpoint.py` to test all endpoints:
- Health checks
- Inbound webhook with Zep/GHL integration
- Calendar availability
- Full appointment lifecycle (book → reschedule → cancel)
- Call transcript storage

Tests use `+15551234567` as test phone number.

## Logging

All major operations are logged with context:
- Inbound calls: call_id and from_number
- Zep queries: user_id and fact count
- GHL operations: contact_id and operation type
- Appointment operations: event_id and action
- Errors: full exception info with exc_info=True

## Railway Deployment Notes

- Procfile and railway.json both specify start command
- Uses NIXPACKS builder
- Restart policy: ON_FAILURE with max 10 retries
- PORT environment variable auto-set by Railway
- Check logs: `railway logs`
