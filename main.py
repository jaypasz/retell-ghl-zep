"""
Railway-ready FastAPI app for Retell AI with Zep + GHL integration
Optimized with Redis caching and Supabase persistence
Based on DATA_LAYER_OPTIMIZATION.md
"""
import os
import logging
import asyncio
import time
from datetime import datetime, timedelta, date
from typing import Optional, Dict, Any
from fastapi import FastAPI, Request, HTTPException, BackgroundTasks
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
import httpx

# Optional Langfuse integration (safe no-op if not configured)
try:
    from langfuse_client import get_prompt, create_trace
except Exception:
    # If import fails unexpectedly, define no-op fallbacks
    def get_prompt(name, version=None, fallback=None):
        class P:
            prompt = fallback or ""
            version = 0
        return P()

    def create_trace(name, user_id=None, session_id=None, metadata=None):
        class T:
            def generation(self, **kwargs):
                return None
            def score(self, **kwargs):
                return None
            def update(self, **kwargs):
                return None
        return T()

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Import optimization modules
try:
    from cached_clients import (
        CachedMemoryClient,
        CachedCalendarClient,
        ContextCache,
        create_redis_client
    )
    from supabase_client import create_supabase_client
    OPTIMIZATION_AVAILABLE = True
except ImportError:
    logger.warning("Optimization modules not available - install redis and supabase")
    OPTIMIZATION_AVAILABLE = False

# Environment variables
ZEP_API_KEY = os.getenv("ZEP_API_KEY")
ZEP_API_URL = os.getenv("ZEP_API_URL", "https://api.getzep.com")
GHL_API_KEY = os.getenv("GHL_API_KEY")
GHL_LOCATION_ID = os.getenv("GHL_LOCATION_ID")
GHL_CALENDAR_ID = os.getenv("GHL_CALENDAR_ID")  # Calendar ID for appointments
GHL_TIMEZONE = os.getenv("GHL_TIMEZONE", "America/New_York")  # Timezone for appointments
RETELL_API_KEY = os.getenv("RETELL_API_KEY")

# Optimization variables
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")

app = FastAPI(title="Retell-Zep-GHL Integration (Optimized)")


# Pydantic models
class RetellInboundRequest(BaseModel):
    """Request model for Retell inbound calls"""
    call_id: str
    from_number: str
    to_number: str
    direction: str = "inbound"
    metadata: Optional[Dict[str, Any]] = None


class RetellDynamicVariables(BaseModel):
    """Response model for Retell dynamic variables"""
    dynamic_variables: Dict[str, Any] = Field(default_factory=dict)


# Zep Client
class ZepClient:
    """Client for interacting with Zep memory API"""
    
    def __init__(self, api_key: str, base_url: str):
        self.api_key = api_key
        self.base_url = base_url.rstrip('/')
        self.headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        }
    
    async def get_user_memory(self, user_id: str, session_id: Optional[str] = None) -> Dict[str, Any]:
        """Retrieve user memory from Zep"""
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                # Get user details
                user_url = f"{self.base_url}/api/v2/users/{user_id}"
                user_response = await client.get(user_url, headers=self.headers)
                
                if user_response.status_code == 404:
                    logger.info(f"User {user_id} not found in Zep, returning empty memory")
                    return {"user_id": user_id, "facts": [], "sessions": []}
                
                user_response.raise_for_status()
                user_data = user_response.json()
                
                # Get user's facts (long-term memory)
                facts = user_data.get("metadata", {}).get("facts", [])
                
                # Get session memory if session_id provided
                session_memory = None
                if session_id:
                    session_url = f"{self.base_url}/api/v2/sessions/{session_id}/memory"
                    session_response = await client.get(session_url, headers=self.headers)
                    if session_response.status_code == 200:
                        session_memory = session_response.json()
                
                return {
                    "user_id": user_id,
                    "facts": facts,
                    "session_memory": session_memory,
                    "user_metadata": user_data.get("metadata", {})
                }
                
        except httpx.HTTPStatusError as e:
            logger.error(f"Zep API error: {e.response.status_code} - {e.response.text}")
            return {"user_id": user_id, "error": str(e)}
        except Exception as e:
            logger.error(f"Error querying Zep: {str(e)}")
            return {"user_id": user_id, "error": str(e)}


# GHL Client
class GHLClient:
    """Client for interacting with Go High Level API"""
    
    def __init__(self, api_key: str, location_id: str):
        self.api_key = api_key
        self.location_id = location_id
        self.base_url = "https://services.leadconnectorhq.com"
        self.headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Version": "2021-07-28"
        }
    
    async def upsert_contact(self, phone: str, data: Dict[str, Any]) -> Dict[str, Any]:
        """Upsert contact in GHL by phone number"""
        try:
            # Clean phone number
            clean_phone = phone.replace("+", "").replace("-", "").replace(" ", "")
            
            async with httpx.AsyncClient(timeout=15.0) as client:
                # Search for existing contact by phone
                search_url = f"{self.base_url}/contacts/search/duplicate"
                search_params = {
                    "locationId": self.location_id,
                    "phone": clean_phone
                }
                
                search_response = await client.post(
                    search_url,
                    headers=self.headers,
                    json=search_params
                )
                
                contact_id = None
                if search_response.status_code == 200:
                    search_data = search_response.json()
                    if search_data.get("contact"):
                        contact_id = search_data["contact"]["id"]
                
                # Prepare contact data
                contact_data = {
                    "locationId": self.location_id,
                    "phone": clean_phone,
                    **data
                }
                
                if contact_id:
                    # Update existing contact
                    update_url = f"{self.base_url}/contacts/{contact_id}"
                    response = await client.put(
                        update_url,
                        headers=self.headers,
                        json=contact_data
                    )
                    logger.info(f"Updated GHL contact: {contact_id}")
                else:
                    # Create new contact
                    create_url = f"{self.base_url}/contacts/"
                    response = await client.post(
                        create_url,
                        headers=self.headers,
                        json=contact_data
                    )
                    logger.info(f"Created new GHL contact")
                
                response.raise_for_status()
                return response.json()
                
        except httpx.HTTPStatusError as e:
            logger.error(f"GHL API error: {e.response.status_code} - {e.response.text}")
            return {"error": str(e), "status_code": e.response.status_code}
        except Exception as e:
            logger.error(f"Error upserting to GHL: {str(e)}")
            return {"error": str(e)}
    
    async def get_available_slots(self, calendar_id: str, start_date: str, end_date: str, 
                                   timezone: str = "America/New_York") -> Dict[str, Any]:
        """
        Get available appointment slots from GHL calendar
        
        Args:
            calendar_id: GHL calendar ID
            start_date: Start date in YYYY-MM-DD format
            end_date: End date in YYYY-MM-DD format
            timezone: Timezone string (e.g., "America/New_York")
        """
        try:
            async with httpx.AsyncClient(timeout=15.0) as client:
                url = f"{self.base_url}/calendars/{calendar_id}/free-slots"
                params = {
                    "startDate": start_date,
                    "endDate": end_date,
                    "timezone": timezone
                }
                
                response = await client.get(url, headers=self.headers, params=params)
                response.raise_for_status()
                
                slots_data = response.json()
                logger.info(f"Retrieved {len(slots_data.get('slots', []))} available slots")
                return slots_data
                
        except httpx.HTTPStatusError as e:
            logger.error(f"GHL calendar API error: {e.response.status_code} - {e.response.text}")
            return {"error": str(e), "slots": []}
        except Exception as e:
            logger.error(f"Error getting calendar slots: {str(e)}")
            return {"error": str(e), "slots": []}
    
    async def book_appointment(self, calendar_id: str, contact_id: str, 
                               slot_time: str, appointment_data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Book an appointment in GHL calendar
        
        Args:
            calendar_id: GHL calendar ID
            contact_id: GHL contact ID
            slot_time: ISO 8601 datetime string for appointment start
            appointment_data: Additional appointment details (title, notes, etc.)
        """
        try:
            async with httpx.AsyncClient(timeout=15.0) as client:
                url = f"{self.base_url}/calendars/events/appointments"
                
                # Build appointment payload
                payload = {
                    "calendarId": calendar_id,
                    "locationId": self.location_id,
                    "contactId": contact_id,
                    "startTime": slot_time,
                    "title": appointment_data.get("title", "Appointment"),
                    "appointmentStatus": "confirmed",
                    **appointment_data
                }
                
                response = await client.post(url, headers=self.headers, json=payload)
                response.raise_for_status()
                
                appointment = response.json()
                event_id = appointment.get("id") or appointment.get("event", {}).get("id")
                logger.info(f"Booked appointment: {event_id} for contact {contact_id}")
                return appointment
                
        except httpx.HTTPStatusError as e:
            logger.error(f"GHL booking API error: {e.response.status_code} - {e.response.text}")
            return {"error": str(e), "status_code": e.response.status_code}
        except Exception as e:
            logger.error(f"Error booking appointment: {str(e)}")
            return {"error": str(e)}
    
    async def reschedule_appointment(self, event_id: str, new_start_time: str) -> Dict[str, Any]:
        """
        Reschedule an existing appointment
        
        Args:
            event_id: GHL event/appointment ID
            new_start_time: New ISO 8601 datetime string
        """
        try:
            async with httpx.AsyncClient(timeout=15.0) as client:
                url = f"{self.base_url}/calendars/events/{event_id}"
                
                payload = {
                    "startTime": new_start_time
                }
                
                response = await client.put(url, headers=self.headers, json=payload)
                response.raise_for_status()
                
                logger.info(f"Rescheduled appointment: {event_id}")
                return response.json()
                
        except httpx.HTTPStatusError as e:
            logger.error(f"GHL reschedule API error: {e.response.status_code} - {e.response.text}")
            return {"error": str(e), "status_code": e.response.status_code}
        except Exception as e:
            logger.error(f"Error rescheduling appointment: {str(e)}")
            return {"error": str(e)}
    
    async def cancel_appointment(self, event_id: str) -> Dict[str, Any]:
        """
        Cancel an appointment
        
        Args:
            event_id: GHL event/appointment ID
        """
        try:
            async with httpx.AsyncClient(timeout=15.0) as client:
                url = f"{self.base_url}/calendars/events/{event_id}"
                
                response = await client.delete(url, headers=self.headers)
                response.raise_for_status()
                
                logger.info(f"Cancelled appointment: {event_id}")
                return {"success": True, "event_id": event_id}
                
        except httpx.HTTPStatusError as e:
            logger.error(f"GHL cancel API error: {e.response.status_code} - {e.response.text}")
            return {"error": str(e), "status_code": e.response.status_code}
        except Exception as e:
            logger.error(f"Error cancelling appointment: {str(e)}")
            return {"error": str(e)}
    
    async def get_contact_appointments(self, contact_id: str) -> Dict[str, Any]:
        """
        Get all appointments for a contact
        
        Args:
            contact_id: GHL contact ID
        """
        try:
            async with httpx.AsyncClient(timeout=15.0) as client:
                url = f"{self.base_url}/calendars/events"
                params = {
                    "locationId": self.location_id,
                    "contactId": contact_id
                }
                
                response = await client.get(url, headers=self.headers, params=params)
                response.raise_for_status()
                
                appointments = response.json()
                logger.info(f"Retrieved {len(appointments.get('events', []))} appointments for contact {contact_id}")
                return appointments
                
        except httpx.HTTPStatusError as e:
            logger.error(f"GHL appointments API error: {e.response.status_code} - {e.response.text}")
            return {"error": str(e), "events": []}
        except Exception as e:
            logger.error(f"Error getting appointments: {str(e)}")
            return {"error": str(e), "events": []}


# Initialize base clients
zep_client = ZepClient(ZEP_API_KEY, ZEP_API_URL) if ZEP_API_KEY else None
ghl_client = GHLClient(GHL_API_KEY, GHL_LOCATION_ID) if GHL_API_KEY and GHL_LOCATION_ID else None

# Initialize optimization clients (will be set on startup)
redis_client = None
cached_memory_client = None
cached_calendar_client = None
context_cache = None
supabase_client = None


@app.on_event("startup")
async def startup_event():
    """Initialize optimization clients on startup"""
    global redis_client, cached_memory_client, cached_calendar_client, context_cache, supabase_client

    if OPTIMIZATION_AVAILABLE:
        # Initialize Redis
        try:
            redis_client = await create_redis_client(REDIS_URL)
            logger.info("Redis client initialized successfully")

            # Initialize cached clients
            if zep_client:
                cached_memory_client = CachedMemoryClient(zep_client, redis_client)
                logger.info("Cached memory client initialized")

            if ghl_client:
                cached_calendar_client = CachedCalendarClient(ghl_client, redis_client)
                logger.info("Cached calendar client initialized")

            context_cache = ContextCache(redis_client)
            logger.info("Context cache initialized")

        except Exception as e:
            logger.error(f"Failed to initialize Redis: {e}")
            logger.warning("Continuing without Redis optimization")

        # Initialize Supabase
        try:
            supabase_client = create_supabase_client(SUPABASE_URL, SUPABASE_KEY)
            if supabase_client:
                logger.info("Supabase client initialized successfully")
        except Exception as e:
            logger.error(f"Failed to initialize Supabase: {e}")
            logger.warning("Continuing without Supabase persistence")
    else:
        logger.warning("Optimization not available - running in legacy mode")


@app.on_event("shutdown")
async def shutdown_event():
    """Cleanup on shutdown"""
    if redis_client:
        try:
            await redis_client.close()
            logger.info("Redis connection closed")
        except Exception as e:
            logger.error(f"Error closing Redis: {e}")


# ============================================================================
# BACKGROUND TASK FUNCTIONS
# These run AFTER the webhook returns, without blocking the response
# ============================================================================

async def update_all_systems_background(
    call_id: str,
    phone: str,
    user_id: str,
    metadata: Dict[str, Any],
    body: Dict[str, Any]
):
    """
    Update all external systems in background

    This runs AFTER the webhook returns to avoid blocking the response.
    Updates GHL CRM, Zep memory, Supabase logs, and metrics.

    Args:
        call_id: Retell call ID
        phone: Customer phone number (with formatting)
        user_id: Normalized phone number
        metadata: Call metadata
        body: Full webhook body
    """
    logger.info(f"Starting background updates for call {call_id}")
    bg_start = time.time()

    # 1. Log call to Supabase (50ms)
    if supabase_client:
        try:
            await supabase_client.log_call({
                "call_id": call_id,
                "phone_number": user_id,
                "call_started_at": datetime.utcnow().isoformat(),
                "metadata": metadata
            })
            logger.debug("Call logged to Supabase")
        except Exception as e:
            logger.error(f"Supabase log_call failed: {e}")

    # 2. Update/create CRM contact (200ms)
    if ghl_client:
        try:
            ghl_data = {
                "source": "Retell AI Inbound",
                "tags": ["retell-inbound", "voice-ai"],
                "customField": {
                    "last_call_id": call_id,
                    "last_call_time": datetime.utcnow().isoformat()
                }
            }

            if metadata:
                ghl_data["customField"].update(metadata)

            ghl_contact = await ghl_client.upsert_contact(phone, ghl_data)

            if "error" not in ghl_contact:
                contact_id = ghl_contact.get("contact", {}).get("id") or ghl_contact.get("id")
                logger.info(f"CRM updated: {phone} -> {contact_id}")

                # Update Supabase with GHL ID
                if supabase_client:
                    try:
                        await supabase_client.upsert_contact({
                            "phone_number": user_id,
                            "ghl_contact_id": contact_id,
                            "last_call_at": datetime.utcnow().isoformat()
                        })
                        logger.debug("Contact synced to Supabase")
                    except Exception as e:
                        logger.error(f"Supabase upsert_contact failed: {e}")
            else:
                logger.error(f"GHL upsert failed: {ghl_contact.get('error')}")

        except Exception as e:
            logger.error(f"CRM update failed: {e}")

    # 3. Update daily metrics
    if supabase_client:
        try:
            today = date.today().isoformat()
            await supabase_client.update_daily_metrics(
                date=today,
                metrics={"total_calls": 1}
            )
            logger.debug("Daily metrics updated")
        except Exception as e:
            logger.error(f"Metrics update failed: {e}")

    bg_time = (time.time() - bg_start) * 1000
    logger.info(f"Background updates completed for {call_id} ({bg_time:.0f}ms)")


async def refresh_context_cache(user_id: str, call_id: str):
    """
    Refresh context cache in background

    Ensures cache stays warm with latest data.
    Called after returning cached response.

    Args:
        user_id: Normalized phone number
        call_id: Current call ID
    """
    try:
        logger.debug(f"Refreshing context cache for {user_id}")

        # Re-fetch all context components
        dynamic_vars = {
            "customer_known": "unknown",
            "available_slots": [],
            "has_availability": False
        }

        # Fetch memory
        if cached_memory_client:
            memory = await cached_memory_client.get_memory(user_id, call_id, force_refresh=True)
            facts = memory.get("facts", [])
            if facts:
                dynamic_vars["customer_facts"] = facts
                dynamic_vars["customer_known"] = "yes"
                dynamic_vars["customer_summary"] = f"Customer has {len(facts)} known facts"

        # Fetch contact
        if supabase_client:
            contact = await supabase_client.get_contact_fast(user_id)
            if contact:
                dynamic_vars["customer_name"] = contact.get("name")
                dynamic_vars["total_calls"] = contact.get("total_calls", 0)

        # Fetch calendar slots
        if cached_calendar_client and GHL_CALENDAR_ID:
            start_date = datetime.utcnow().strftime("%Y-%m-%d")
            end_date = (datetime.utcnow() + timedelta(days=7)).strftime("%Y-%m-%d")
            slots_result = await cached_calendar_client.get_available_slots(
                GHL_CALENDAR_ID, start_date, end_date, GHL_TIMEZONE, force_refresh=True
            )

            if slots_result and "error" not in slots_result:
                available_slots = slots_result.get("slots", [])
                formatted_slots = []
                for slot in available_slots[:5]:
                    try:
                        slot_time = datetime.fromisoformat(slot.replace('Z', '+00:00'))
                        formatted_slots.append({
                            "datetime": slot,
                            "formatted": slot_time.strftime("%A, %B %d at %I:%M %p"),
                            "date": slot_time.strftime("%Y-%m-%d"),
                            "time": slot_time.strftime("%I:%M %p")
                        })
                    except Exception:
                        pass

                dynamic_vars["available_slots"] = formatted_slots
                dynamic_vars["has_availability"] = len(formatted_slots) > 0

        # Update cache
        if context_cache:
            await context_cache.set_context(user_id, dynamic_vars)
            logger.info(f"Context cache refreshed for {user_id}")

    except Exception as e:
        logger.error(f"Cache refresh failed: {e}")


async def log_appointment_to_supabase(
    user_id: str,
    ghl_appointment_id: str,
    scheduled_at: str,
    status: str
):
    """
    Log appointment to Supabase (background task)

    Args:
        user_id: Normalized phone number
        ghl_appointment_id: GHL appointment ID
        scheduled_at: ISO timestamp
        status: Appointment status
    """
    try:
        if not supabase_client:
            return

        # Get contact ID from Supabase
        contact = await supabase_client.get_contact_fast(user_id)
        if not contact:
            logger.warning(f"Contact not found in Supabase for {user_id}")
            return

        await supabase_client.create_appointment({
            "contact_id": contact["id"],
            "ghl_appointment_id": ghl_appointment_id,
            "scheduled_at": scheduled_at,
            "status": status
        })

        logger.info(f"Appointment logged to Supabase: {ghl_appointment_id}")

    except Exception as e:
        logger.error(f"Failed to log appointment to Supabase: {e}")


@app.get("/")
async def root():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "service": "Retell-Zep-GHL Integration",
        "timestamp": datetime.utcnow().isoformat(),
        "integrations": {
            "zep": bool(zep_client),
            "ghl": bool(ghl_client)
        }
    }


@app.get("/health")
async def health_check():
    """Detailed health check"""
    return {
        "status": "healthy",
        "zep_configured": bool(ZEP_API_KEY),
        "ghl_configured": bool(GHL_API_KEY and GHL_LOCATION_ID),
        "retell_configured": bool(RETELL_API_KEY)
    }


@app.post("/retell/inbound")
async def retell_inbound_webhook(request: Request, background_tasks: BackgroundTasks):
    """
    OPTIMIZED Retell inbound call webhook handler

    Strategy:
    1. Check full context cache (Redis) - instant if hit
    2. If cache miss: build context from sources (Supabase + cached APIs)
    3. Schedule slow operations (CRM, Zep updates, logging) in background
    4. Return response FAST (target: <100ms)

    Performance targets:
    - Cached: 30-50ms
    - Uncached: 80-100ms
    - Background tasks don't block response
    """
    overall_start = time.time()

    try:
        # Parse request body (10ms)
        body = await request.json()
        logger.info(f"Received Retell inbound call: {body.get('call_id')}")

        # Extract key fields
        call_id = body.get("call_id")
        from_number = body.get("from_number", body.get("customer_number"))
        to_number = body.get("to_number")
        metadata = body.get("metadata", {})

        if not from_number:
            raise HTTPException(status_code=400, detail="Missing from_number/customer_number")

        # Normalize phone for use as user_id
        user_id = from_number.replace("+", "").replace("-", "").replace(" ", "")

        # ===== CRITICAL PATH (synchronous - minimize latency) =====

        # Try full context cache first (5-10ms if hit)
        cached_context = None
        if context_cache:
            cached_context = await context_cache.get_context(user_id)

        if cached_context:
            # CACHE HIT - Ultra fast response! ✨
            logger.info(f"⚡ Full context cache HIT for {user_id}")

            # Schedule background refresh to keep cache warm
            background_tasks.add_task(
                refresh_context_cache,
                user_id=user_id,
                call_id=call_id
            )

            # Add real-time data
            cached_context["call_id"] = call_id
            cached_context["customer_phone"] = from_number
            cached_context["timestamp"] = datetime.utcnow().isoformat()

            # Build response immediately
            response = {"dynamic_variables": cached_context}

            total_time = (time.time() - overall_start) * 1000
            logger.info(f"⚡ Webhook (cached): {total_time:.0f}ms")

            return JSONResponse(content=response)

        # CACHE MISS - Build context from sources
        logger.info(f"Context cache MISS for {user_id}")

        # Initialize response variables
        dynamic_vars = {
            "call_id": call_id,
            "customer_phone": from_number,
            "timestamp": datetime.utcnow().isoformat(),
        }

        # Parallel fetch from multiple sources (use cached clients when available)
        fetch_start = time.time()

        # Memory query (use cached client if available, ~5-10ms if cached, ~150ms if not)
        memory_task = None
        if cached_memory_client:
            memory_task = cached_memory_client.get_memory(user_id, call_id)
        elif zep_client:
            memory_task = zep_client.get_user_memory(user_id, call_id)

        # Contact lookup (Supabase is fast ~20ms)
        contact_task = None
        if supabase_client:
            contact_task = supabase_client.get_contact_fast(user_id)

        # Calendar slots (use cached client if available, ~5ms if cached, ~140ms if not)
        slots_task = None
        if cached_calendar_client and GHL_CALENDAR_ID:
            start_date = datetime.utcnow().strftime("%Y-%m-%d")
            end_date = (datetime.utcnow() + timedelta(days=7)).strftime("%Y-%m-%d")
            slots_task = cached_calendar_client.get_available_slots(
                GHL_CALENDAR_ID, start_date, end_date, GHL_TIMEZONE
            )

        # Prompt (Langfuse - assume cached)
        try:
            prompt_name = "greeting-new-customer"  # Will update based on memory
            prompt_obj = get_prompt(prompt_name, fallback="Hi! Thanks for calling. How can I help you today?")
            system_prompt = getattr(prompt_obj, "prompt", str(prompt_obj))
        except Exception:
            system_prompt = "Hi! Thanks for calling. How can I help you today?"

        # Gather results
        tasks = [t for t in [memory_task, contact_task, slots_task] if t]
        results = await asyncio.gather(*tasks, return_exceptions=True) if tasks else []

        fetch_time = (time.time() - fetch_start) * 1000
        logger.info(f"Parallel fetch completed: {fetch_time:.0f}ms")

        # Process memory results
        zep_memory = results[0] if memory_task and len(results) > 0 else {}
        if isinstance(zep_memory, Exception):
            logger.error(f"Memory fetch failed: {zep_memory}")
            zep_memory = {}

        facts = zep_memory.get("facts", [])
        if facts:
            dynamic_vars["customer_facts"] = facts
            dynamic_vars["customer_known"] = "yes"
            dynamic_vars["customer_summary"] = f"Customer has {len(facts)} known facts"
        else:
            dynamic_vars["customer_known"] = "no"
            dynamic_vars["customer_summary"] = "New customer, no previous interactions"

        # Process contact results
        contact = results[1] if contact_task and len(results) > 1 else None
        if isinstance(contact, Exception):
            logger.error(f"Contact fetch failed: {contact}")
            contact = None

        if contact:
            dynamic_vars["customer_name"] = contact.get("name")
            dynamic_vars["total_calls"] = contact.get("total_calls", 0)

        # Process slots results
        slots_result = results[2] if slots_task and len(results) > 2 else None
        if isinstance(slots_result, Exception):
            logger.error(f"Slots fetch failed: {slots_result}")
            slots_result = None

        if slots_result and "error" not in slots_result:
            available_slots = slots_result.get("slots", [])

            # Format slots for Retell agent
            formatted_slots = []
            for slot in available_slots[:5]:  # Return top 5 slots
                try:
                    slot_time = datetime.fromisoformat(slot.replace('Z', '+00:00'))
                    formatted_slots.append({
                        "datetime": slot,
                        "formatted": slot_time.strftime("%A, %B %d at %I:%M %p"),
                        "date": slot_time.strftime("%Y-%m-%d"),
                        "time": slot_time.strftime("%I:%M %p")
                    })
                except Exception:
                    pass

            dynamic_vars["available_slots"] = formatted_slots
            dynamic_vars["has_availability"] = len(formatted_slots) > 0
            dynamic_vars["slots_count"] = len(formatted_slots)
        else:
            dynamic_vars["has_availability"] = False
            dynamic_vars["available_slots"] = []

        dynamic_vars["system_prompt"] = system_prompt

        # Cache context for next call (5min TTL)
        if context_cache:
            background_tasks.add_task(
                context_cache.set_context,
                phone=user_id,
                context=dynamic_vars
            )

        # ===== END CRITICAL PATH =====

        # Schedule background tasks (don't wait!)
        background_tasks.add_task(
            update_all_systems_background,
            call_id=call_id,
            phone=from_number,
            user_id=user_id,
            metadata=metadata,
            body=body
        )

        # Build and return response
        response = {"dynamic_variables": dynamic_vars}

        total_time = (time.time() - overall_start) * 1000
        logger.info(f"⚡ Webhook (uncached): {total_time:.0f}ms")

        return JSONResponse(content=response)

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error processing Retell inbound: {str(e)}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")


@app.post("/retell/call-ended")
async def retell_call_ended(request: Request):
    """
    Optional: Handle call-ended webhook to store transcript in Zep
    """
    try:
        body = await request.json()
        logger.info(f"Received call-ended webhook: {body.get('call_id')}")
        
        # Extract call data
        call_id = body.get("call_id")
        transcript = body.get("transcript")
        from_number = body.get("from_number", body.get("customer_number"))
        
        if zep_client and transcript and from_number:
            user_id = from_number.replace("+", "").replace("-", "").replace(" ", "")
            
            # Store transcript as a session in Zep
            async with httpx.AsyncClient(timeout=15.0) as client:
                session_url = f"{zep_client.base_url}/api/v2/sessions"
                session_data = {
                    "session_id": call_id,
                    "user_id": user_id,
                    "metadata": {
                        "call_type": "inbound",
                        "timestamp": datetime.utcnow().isoformat()
                    }
                }
                
                # Create/update session
                await client.post(
                    session_url,
                    headers=zep_client.headers,
                    json=session_data
                )
                
                # Add messages to session
                messages_url = f"{session_url}/{call_id}/messages"
                messages_data = {
                    "messages": [
                        {
                            "role": "assistant",
                            "content": transcript,
                            "metadata": {"source": "retell_transcript"}
                        }
                    ]
                }
                
                await client.post(
                    messages_url,
                    headers=zep_client.headers,
                    json=messages_data
                )
                
                logger.info(f"Stored transcript in Zep for session: {call_id}")
        
        return {"status": "success", "message": "Call ended processed"}
        
    except Exception as e:
        logger.error(f"Error processing call-ended: {str(e)}", exc_info=True)
        return {"status": "error", "message": str(e)}


# ============================================================================
# APPOINTMENT MANAGEMENT ENDPOINTS
# These endpoints can be called by Retell custom tools during a call
# ============================================================================

@app.post("/appointments/book")
async def book_appointment(request: Request, background_tasks: BackgroundTasks):
    """
    Book a new appointment

    OPTIMIZED: Invalidates calendar cache and logs to Supabase

    Request body:
    {
        "contact_id": "ghl_contact_id",
        "calendar_id": "optional_calendar_id",
        "slot_time": "2024-01-15T14:00:00Z",
        "title": "Appointment Title",
        "notes": "Additional notes",
        "customer_phone": "+15551234567"
    }
    """
    try:
        body = await request.json()
        logger.info(f"Booking appointment request: {body}")

        contact_id = body.get("contact_id")
        calendar_id = body.get("calendar_id", GHL_CALENDAR_ID)
        slot_time = body.get("slot_time")
        customer_phone = body.get("customer_phone")

        if not contact_id:
            # Try to find contact by phone if not provided
            if customer_phone and ghl_client:
                ghl_result = await ghl_client.upsert_contact(
                    customer_phone,
                    {"source": "Retell AI Booking"}
                )
                contact_id = ghl_result.get("contact", {}).get("id") or ghl_result.get("id")

        if not all([contact_id, calendar_id, slot_time]):
            raise HTTPException(
                status_code=400,
                detail="Missing required fields: contact_id, calendar_id, slot_time"
            )

        if not ghl_client:
            raise HTTPException(status_code=503, detail="GHL client not configured")

        # Book the appointment
        appointment_data = {
            "title": body.get("title", "Phone Appointment"),
            "notes": body.get("notes", ""),
            "assignedUserId": body.get("assigned_user_id")
        }

        result = await ghl_client.book_appointment(
            calendar_id=calendar_id,
            contact_id=contact_id,
            slot_time=slot_time,
            appointment_data=appointment_data
        )

        if "error" in result:
            raise HTTPException(
                status_code=result.get("status_code", 500),
                detail=result.get("error")
            )

        # Invalidate calendar cache (slot no longer available)
        if cached_calendar_client:
            background_tasks.add_task(
                cached_calendar_client.invalidate_slot,
                calendar_id=calendar_id
            )

        # Log appointment to Supabase
        if supabase_client and customer_phone:
            user_id = customer_phone.replace("+", "").replace("-", "").replace(" ", "")
            background_tasks.add_task(
                log_appointment_to_supabase,
                user_id=user_id,
                ghl_appointment_id=result.get("id"),
                scheduled_at=slot_time,
                status="scheduled"
            )

        # Update metrics
        if supabase_client:
            background_tasks.add_task(
                supabase_client.update_daily_metrics,
                date=date.today().isoformat(),
                metrics={"appointments_booked": 1}
            )

        return {
            "success": True,
            "appointment": result,
            "message": "Appointment booked successfully"
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error booking appointment: {str(e)}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/appointments/reschedule")
async def reschedule_appointment(request: Request):
    """
    Reschedule an existing appointment
    
    Request body:
    {
        "event_id": "appointment_id",
        "new_start_time": "2024-01-16T15:00:00Z"
    }
    """
    try:
        body = await request.json()
        logger.info(f"Rescheduling appointment request: {body}")
        
        event_id = body.get("event_id")
        new_start_time = body.get("new_start_time")
        
        if not all([event_id, new_start_time]):
            raise HTTPException(
                status_code=400,
                detail="Missing required fields: event_id, new_start_time"
            )
        
        if not ghl_client:
            raise HTTPException(status_code=503, detail="GHL client not configured")
        
        result = await ghl_client.reschedule_appointment(event_id, new_start_time)
        
        if "error" in result:
            raise HTTPException(
                status_code=result.get("status_code", 500),
                detail=result.get("error")
            )
        
        return {
            "success": True,
            "appointment": result,
            "message": "Appointment rescheduled successfully"
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error rescheduling appointment: {str(e)}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/appointments/cancel")
async def cancel_appointment(request: Request):
    """
    Cancel an appointment
    
    Request body:
    {
        "event_id": "appointment_id"
    }
    """
    try:
        body = await request.json()
        logger.info(f"Canceling appointment request: {body}")
        
        event_id = body.get("event_id")
        
        if not event_id:
            raise HTTPException(status_code=400, detail="Missing required field: event_id")
        
        if not ghl_client:
            raise HTTPException(status_code=503, detail="GHL client not configured")
        
        result = await ghl_client.cancel_appointment(event_id)
        
        if "error" in result:
            raise HTTPException(
                status_code=result.get("status_code", 500),
                detail=result.get("error")
            )
        
        return {
            "success": True,
            "event_id": event_id,
            "message": "Appointment cancelled successfully"
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error cancelling appointment: {str(e)}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/appointments/availability")
async def get_availability(
    calendar_id: Optional[str] = None,
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    timezone: Optional[str] = None
):
    """
    Get available appointment slots
    
    Query parameters:
    - calendar_id: GHL calendar ID (optional, uses default if not provided)
    - start_date: Start date in YYYY-MM-DD format (optional, defaults to today)
    - end_date: End date in YYYY-MM-DD format (optional, defaults to 7 days from now)
    - timezone: Timezone string (optional, uses default)
    """
    try:
        if not ghl_client:
            raise HTTPException(status_code=503, detail="GHL client not configured")
        
        calendar_id = calendar_id or GHL_CALENDAR_ID
        if not calendar_id:
            raise HTTPException(status_code=400, detail="Calendar ID not configured")
        
        start_date = start_date or datetime.utcnow().strftime("%Y-%m-%d")
        end_date = end_date or (datetime.utcnow() + timedelta(days=7)).strftime("%Y-%m-%d")
        timezone = timezone or GHL_TIMEZONE
        
        result = await ghl_client.get_available_slots(
            calendar_id=calendar_id,
            start_date=start_date,
            end_date=end_date,
            timezone=timezone
        )
        
        if "error" in result:
            raise HTTPException(status_code=500, detail=result.get("error"))
        
        return result
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting availability: {str(e)}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", 8000))
    uvicorn.run(app, host="0.0.0.0", port=port)
