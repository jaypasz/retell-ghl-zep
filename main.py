"""
Railway-ready FastAPI app for Retell AI with Zep + GHL integration
"""
import os
import logging
from datetime import datetime, timedelta
from typing import Optional, Dict, Any
from fastapi import FastAPI, Request, HTTPException
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

# Environment variables
ZEP_API_KEY = os.getenv("ZEP_API_KEY")
ZEP_API_URL = os.getenv("ZEP_API_URL", "https://api.getzep.com")
GHL_API_KEY = os.getenv("GHL_API_KEY")
GHL_LOCATION_ID = os.getenv("GHL_LOCATION_ID")
GHL_CALENDAR_ID = os.getenv("GHL_CALENDAR_ID")  # Calendar ID for appointments
GHL_TIMEZONE = os.getenv("GHL_TIMEZONE", "America/New_York")  # Timezone for appointments
RETELL_API_KEY = os.getenv("RETELL_API_KEY")

app = FastAPI(title="Retell-Zep-GHL Integration")


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


# Initialize clients
zep_client = ZepClient(ZEP_API_KEY, ZEP_API_URL) if ZEP_API_KEY else None
ghl_client = GHLClient(GHL_API_KEY, GHL_LOCATION_ID) if GHL_API_KEY and GHL_LOCATION_ID else None


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
async def retell_inbound_webhook(request: Request):
    """
    Retell inbound call webhook handler
    
    Flow:
    1. Receive Retell inbound call data
    2. Query Zep for user memory (using phone number as user_id)
    3. Upsert contact info into GHL
    4. Return dynamic_variables to Retell for agent context
    """
    try:
        # Parse request body
        body = await request.json()
        logger.info(f"Received Retell inbound call: {body}")
        
        # Extract key fields
        call_id = body.get("call_id")
        from_number = body.get("from_number", body.get("customer_number"))
        to_number = body.get("to_number")
        metadata = body.get("metadata", {})
        
        if not from_number:
            raise HTTPException(status_code=400, detail="Missing from_number/customer_number")
        
        # Normalize phone for use as user_id
        user_id = from_number.replace("+", "").replace("-", "").replace(" ", "")
        
        # Initialize response variables
        dynamic_vars = {
            "call_id": call_id,
            "customer_phone": from_number,
            "timestamp": datetime.utcnow().isoformat(),
        }

        # Create a Langfuse trace (will be a dummy trace if Langfuse not configured)
        try:
            trace = create_trace(name="inbound-call", user_id=from_number, session_id=call_id, metadata={"from": from_number})
        except Exception:
            trace = None
        
        # 1. Query Zep for user memory
        if zep_client:
            logger.info(f"Querying Zep for user: {user_id}")
            zep_memory = await zep_client.get_user_memory(
                user_id=user_id,
                session_id=call_id
            )
            
            # Extract relevant facts for agent
            facts = zep_memory.get("facts", [])
            if facts:
                dynamic_vars["customer_facts"] = facts
                dynamic_vars["customer_known"] = "yes"
                # Create a summary for the agent
                dynamic_vars["customer_summary"] = f"Customer has {len(facts)} known facts"
            else:
                dynamic_vars["customer_known"] = "no"
                dynamic_vars["customer_summary"] = "New customer, no previous interactions"
            
            logger.info(f"Zep memory retrieved: {len(facts)} facts")
        else:
            logger.warning("Zep client not configured")
            dynamic_vars["customer_known"] = "unknown"
        
        # 2. Upsert contact into GHL
        if ghl_client:
            logger.info(f"Upserting contact to GHL: {from_number}")
            
            ghl_data = {
                "source": "Retell AI Inbound",
                "tags": ["retell-inbound", "voice-ai"],
                "customField": {
                    "last_call_id": call_id,
                    "last_call_time": datetime.utcnow().isoformat()
                }
            }
            
            # Add any metadata from Retell
            if metadata:
                ghl_data["customField"].update(metadata)
            
            ghl_result = await ghl_client.upsert_contact(from_number, ghl_data)
            
            if "error" not in ghl_result:
                contact_id = ghl_result.get("contact", {}).get("id") or ghl_result.get("id")
                dynamic_vars["ghl_contact_id"] = contact_id
                logger.info(f"GHL contact upserted successfully: {contact_id}")
                
                # 3. Get appointment availability and existing appointments
                if GHL_CALENDAR_ID and contact_id:
                    logger.info(f"Fetching calendar availability for calendar: {GHL_CALENDAR_ID}")
                    
                    # Get available slots for next 7 days
                    start_date = datetime.utcnow().strftime("%Y-%m-%d")
                    end_date = (datetime.utcnow() + timedelta(days=7)).strftime("%Y-%m-%d")
                    
                    slots_result = await ghl_client.get_available_slots(
                        calendar_id=GHL_CALENDAR_ID,
                        start_date=start_date,
                        end_date=end_date,
                        timezone=GHL_TIMEZONE
                    )
                    
                    if "error" not in slots_result:
                        available_slots = slots_result.get("slots", [])
                        
                        # Format slots for Retell agent
                        formatted_slots = []
                        for slot in available_slots[:5]:  # Return top 5 slots
                            slot_time = datetime.fromisoformat(slot.replace('Z', '+00:00'))
                            formatted_slots.append({
                                "datetime": slot,
                                "formatted": slot_time.strftime("%A, %B %d at %I:%M %p"),
                                "date": slot_time.strftime("%Y-%m-%d"),
                                "time": slot_time.strftime("%I:%M %p")
                            })
                        
                        dynamic_vars["available_slots"] = formatted_slots
                        dynamic_vars["has_availability"] = len(formatted_slots) > 0
                        dynamic_vars["slots_count"] = len(formatted_slots)
                        logger.info(f"Found {len(formatted_slots)} available slots")
                    else:
                        logger.warning(f"Could not fetch calendar slots: {slots_result.get('error')}")
                        dynamic_vars["has_availability"] = False
                    
                    # Get existing appointments for contact
                    appointments_result = await ghl_client.get_contact_appointments(contact_id)
                    
                    if "error" not in appointments_result:
                        appointments = appointments_result.get("events", [])
                        
                        # Filter for future appointments
                        future_appointments = []
                        current_time = datetime.utcnow()
                        
                        for appt in appointments:
                            appt_time_str = appt.get("startTime")
                            if appt_time_str:
                                appt_time = datetime.fromisoformat(appt_time_str.replace('Z', '+00:00'))
                                if appt_time > current_time:
                                    future_appointments.append({
                                        "id": appt.get("id"),
                                        "title": appt.get("title", "Appointment"),
                                        "datetime": appt_time_str,
                                        "formatted": appt_time.strftime("%A, %B %d at %I:%M %p"),
                                        "status": appt.get("appointmentStatus", "unknown")
                                    })
                        
                        dynamic_vars["existing_appointments"] = future_appointments
                        dynamic_vars["has_existing_appointments"] = len(future_appointments) > 0
                        dynamic_vars["appointment_count"] = len(future_appointments)
                        logger.info(f"Found {len(future_appointments)} future appointments")
                    else:
                        logger.warning(f"Could not fetch appointments: {appointments_result.get('error')}")
                        dynamic_vars["has_existing_appointments"] = False
                else:
                    logger.info("Calendar ID not configured, skipping availability check")
                    
            else:
                logger.error(f"GHL upsert failed: {ghl_result.get('error')}")
                dynamic_vars["ghl_error"] = "Contact sync failed"
        else:
            logger.warning("GHL client not configured")
        
        # Optionally fetch a Langfuse prompt for the initial system prompt
        try:
            # Determine prompt name based on known/new customer
            prompt_name = "greeting-returning-customer" if dynamic_vars.get("customer_known") == "yes" else "greeting-new-customer"
            prompt_obj = get_prompt(prompt_name, fallback="Hi! Thanks for calling. How can I help you today?")
            # prompt_obj may be a Langfuse prompt object or a simple fallback
            system_prompt_text = getattr(prompt_obj, "prompt", str(prompt_obj))
            dynamic_vars["system_prompt"] = system_prompt_text

            # Log prompt usage to Langfuse trace if available
            if trace:
                try:
                    trace.generation(name=f"prompt-{prompt_name}", prompt=system_prompt_text, metadata={"prompt_name": prompt_name, "prompt_version": getattr(prompt_obj, "version", None)})
                except Exception:
                    logger.debug("Langfuse trace.generation failed", exc_info=True)
        except Exception:
            logger.debug("Failed to load Langfuse prompt", exc_info=True)

        response = {"dynamic_variables": dynamic_vars}

        logger.info(f"Returning dynamic variables: {dynamic_vars}")
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
async def book_appointment(request: Request):
    """
    Book a new appointment
    
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
