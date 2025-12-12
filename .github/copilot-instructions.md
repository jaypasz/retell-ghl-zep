<!-- Copilot instructions for the Retell-Zep-GHL integration repo -->
# Guidance for AI coding agents

This repository is a small FastAPI service integrating Retell AI (voice webhooks), Zep (memory), and Go High Level (GHL) CRM. Use the notes below to be productive quickly and follow project conventions.

- Purpose: `main.py` implements all endpoints and clients. Key flows: `/retell/inbound` -> query Zep -> upsert contact in GHL -> return `dynamic_variables` to Retell. See `README.md` and `CLAUDE.md` for examples.

- Quick dev commands:
  - Create venv and install: `python -m venv venv` then `source venv/bin/activate` and `pip install -r requirements.txt`
  - Copy env example: `cp env.example .env` and edit keys
  - Run locally: `uvicorn main:app --reload --port 8000`
  - Run tests (server must be running): `python test_endpoint.py`

- Files to inspect first:
  - `main.py` — All endpoints, `ZepClient` and `GHLClient`, and the booking flow.
  - `README.md` / `CLAUDE.md` — Project overview, env vars, examples and curl snippets.
  - `test_endpoint.py` — Example usage, test phone `+15551234567` and booking flow.

- Environment variables (see `env.example`):
  - `ZEP_API_KEY`, `ZEP_API_URL` (defaults to https://api.getzep.com)
  - `GHL_API_KEY`, `GHL_LOCATION_ID`, `GHL_CALENDAR_ID`, `GHL_TIMEZONE`
  - `RETELL_API_KEY`, `PORT`

- Important conventions and patterns (do not change without reason):
  - Phone normalization: phone numbers are normalized by stripping `+`, `-`, and spaces and used as `user_id` for Zep and as `phone` for GHL lookups. Example from `main.py`:

```python
user_id = from_number.replace("+", "").replace("-", "").replace(" ", "")
```

  - Error handling: external API failures are logged and returned as a dict with an `error` key — the app intentionally avoids raising on third-party failures so the webhook still responds. Follow the same pattern: log with `logger.error(..., exc_info=True)` and return `{"error": ...}`.

  - Async httpx usage: clients use `httpx.AsyncClient` with 10-15s timeouts. Mirror that when adding network calls.

  - GHL API specifics: base URL `https://services.leadconnectorhq.com` and header `Version: 2021-07-28` are required (see `GHLClient.headers` in `main.py`).

- Data shapes and examples you will need:
  - `dynamic_variables` response (required by Retell):

```json
{
  "dynamic_variables": {
    "call_id": "...",
    "customer_phone": "...",
    "customer_known": "yes|no|unknown",
    "customer_facts": [ ... ],
    "ghl_contact_id": "...",
    "available_slots": [ ... ],
    "existing_appointments": [ ... ]
  }
}
```

  - Appointment slot format (how slots are returned to Retell):

```python
{
  "datetime": "ISO8601 string",
  "formatted": "Monday, January 15 at 02:00 PM",
  "date": "2024-01-15",
  "time": "02:00 PM"
}
```

- Where to make safe changes:
  - Add fields to GHL contact payload in `main.py` near the `ghl_data` construction in `/retell/inbound`.
  - Extend Zep/session behavior in `ZepClient` methods; keep the pattern of returning safe dicts on failure.

- Testing and debugging tips:
  - Use `test_endpoint.py` to exercise the full flow (health, inbound webhook, availability, booking lifecycle). It expects the server at `http://localhost:8000` and uses phone `+15551234567`.
  - Key log phrases to grep: `Received Retell inbound call`, `Querying Zep for user`, `Upserting contact to GHL`, `Returning dynamic variables`.
  - If integration keys are missing, clients are `None` (see initialization near top of `main.py`) — the app degrades gracefully. Add checks before using `zep_client`/`ghl_client`.

- Integrations & external behavior to be mindful of:
  - Zep: long-term facts are read from `user.metadata.facts`, session memory via session endpoints. Missing users return 404-safe empty state.
  - GHL: contact upsert uses `contacts/search/duplicate` then `PUT` or `POST` to `/contacts/`. Calendar endpoints return `slots` and `events` structures used by the appointment endpoints.

If anything above is unclear or you want the instructions adjusted (more/less detail, examples, or expanded testing steps), tell me which sections to refine. Thank you! 👋
