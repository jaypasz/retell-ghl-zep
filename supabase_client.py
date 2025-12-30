"""
Supabase client for persistent storage and analytics
Implements database layer from DATA_LAYER_OPTIMIZATION.md
"""
import os
import logging
from typing import Dict, Any, Optional, List
from datetime import datetime, timedelta
from supabase import create_client, Client

logger = logging.getLogger(__name__)


class SupabaseClient:
    """
    Optimized Supabase client for voice AI

    Use cases:
    - Call logs (historical data)
    - Contact management (source of truth)
    - Appointment tracking
    - Analytics and metrics
    - Fallback cache (if Redis down)
    """

    def __init__(self, supabase_url: str, supabase_key: str):
        """
        Initialize Supabase client

        Args:
            supabase_url: Supabase project URL
            supabase_key: Supabase API key (anon or service role)
        """
        self.client: Client = create_client(supabase_url, supabase_key)
        logger.info("Supabase client initialized")

    # ----- FAST READS (use for critical path) -----

    async def get_contact_fast(self, phone: str) -> Optional[Dict[str, Any]]:
        """
        Get contact with minimal data (FAST - ~20ms)

        Args:
            phone: Normalized phone number

        Returns:
            Contact dict or None
        """
        try:
            result = self.client.table("contacts") \
                .select("id, phone_number, name, ghl_contact_id, last_call_at, total_calls") \
                .eq("phone_number", phone) \
                .limit(1) \
                .execute()

            if result.data:
                logger.debug(f"Contact found: {phone}")
                return result.data[0]

            logger.debug(f"Contact not found: {phone}")
            return None

        except Exception as e:
            logger.error(f"Error fetching contact: {e}")
            return None

    async def get_cached_value(self, key: str) -> Optional[Any]:
        """
        Get cached value from Supabase cache table
        Alternative to Redis for fallback

        Args:
            key: Cache key

        Returns:
            Cached value or None
        """
        try:
            result = self.client.table("cache_entries") \
                .select("value") \
                .eq("key", key) \
                .gt("expires_at", datetime.utcnow().isoformat()) \
                .limit(1) \
                .execute()

            if result.data:
                logger.debug(f"Supabase cache HIT: {key}")
                return result.data[0]["value"]

            logger.debug(f"Supabase cache MISS: {key}")
            return None

        except Exception as e:
            logger.error(f"Error reading cache: {e}")
            return None

    async def set_cached_value(
        self,
        key: str,
        value: Any,
        ttl_seconds: int = 300
    ):
        """
        Set cached value with TTL in Supabase

        Args:
            key: Cache key
            value: Value to cache
            ttl_seconds: Time to live in seconds (default 5 minutes)
        """
        try:
            expires_at = datetime.utcnow() + timedelta(seconds=ttl_seconds)

            self.client.table("cache_entries").upsert({
                "key": key,
                "value": value,
                "expires_at": expires_at.isoformat()
            }).execute()

            logger.debug(f"Cached to Supabase: {key} (TTL: {ttl_seconds}s)")

        except Exception as e:
            logger.error(f"Error writing cache: {e}")

    # ----- BACKGROUND WRITES (use after response sent) -----

    async def log_call(self, call_data: Dict[str, Any]):
        """
        Log call to database (background task)

        Args:
            call_data: Call information dict
                - call_id: Retell call ID
                - phone_number: Customer phone
                - call_started_at: ISO timestamp
                - metadata: Additional data
        """
        try:
            self.client.table("call_logs").insert({
                "call_id": call_data["call_id"],
                "phone_number": call_data["phone_number"],
                "call_started_at": call_data["call_started_at"],
                "metadata": call_data.get("metadata", {})
            }).execute()

            logger.info(f"Logged call: {call_data['call_id']}")

        except Exception as e:
            logger.error(f"Failed to log call: {e}")

    async def update_call_ended(
        self,
        call_id: str,
        call_ended_at: str,
        duration_seconds: Optional[int] = None,
        outcome: Optional[str] = None,
        transcript: Optional[Dict] = None
    ):
        """
        Update call log when call ends

        Args:
            call_id: Retell call ID
            call_ended_at: ISO timestamp
            duration_seconds: Call duration
            outcome: Call outcome (e.g., 'appointment_booked', 'transferred')
            transcript: Full transcript data
        """
        try:
            update_data = {
                "call_ended_at": call_ended_at,
                "updated_at": datetime.utcnow().isoformat()
            }

            if duration_seconds:
                update_data["duration_seconds"] = duration_seconds

            if outcome:
                update_data["outcome"] = outcome

            if transcript:
                update_data["transcript"] = transcript

            self.client.table("call_logs") \
                .update(update_data) \
                .eq("call_id", call_id) \
                .execute()

            logger.info(f"Updated call log: {call_id}")

        except Exception as e:
            logger.error(f"Failed to update call: {e}")

    async def upsert_contact(self, contact_data: Dict[str, Any]):
        """
        Create or update contact (background task)

        Args:
            contact_data: Contact information
                - phone_number: Required
                - name: Optional
                - email: Optional
                - ghl_contact_id: GHL reference
                - zep_session_id: Zep reference
                - tags: List of tags
                - custom_fields: Additional data
                - last_call_at: Last call timestamp
                - total_calls: Increment total calls
        """
        try:
            # If updating, increment total_calls
            if "total_calls" not in contact_data:
                existing = await self.get_contact_fast(contact_data["phone_number"])
                if existing:
                    contact_data["total_calls"] = existing.get("total_calls", 0) + 1
                else:
                    contact_data["total_calls"] = 1

            contact_data["updated_at"] = datetime.utcnow().isoformat()

            self.client.table("contacts").upsert(
                contact_data,
                on_conflict="phone_number"
            ).execute()

            logger.info(f"Upserted contact: {contact_data['phone_number']}")

        except Exception as e:
            logger.error(f"Failed to upsert contact: {e}")

    async def create_appointment(self, appointment_data: Dict[str, Any]):
        """
        Create appointment record (background task)

        Args:
            appointment_data: Appointment information
                - contact_id: Supabase contact UUID
                - call_id: Supabase call log UUID (optional)
                - ghl_appointment_id: GHL reference
                - scheduled_at: ISO timestamp
                - status: 'scheduled', 'completed', 'cancelled', 'no_show'
                - notes: Additional notes
        """
        try:
            appointment_data["created_at"] = datetime.utcnow().isoformat()
            appointment_data["updated_at"] = datetime.utcnow().isoformat()

            self.client.table("appointments").insert(
                appointment_data
            ).execute()

            logger.info(f"Created appointment: {appointment_data.get('scheduled_at')}")

        except Exception as e:
            logger.error(f"Failed to create appointment: {e}")

    async def update_appointment_status(
        self,
        ghl_appointment_id: str,
        status: str,
        notes: Optional[str] = None
    ):
        """
        Update appointment status

        Args:
            ghl_appointment_id: GHL appointment ID
            status: New status ('scheduled', 'completed', 'cancelled', 'no_show')
            notes: Optional notes
        """
        try:
            update_data = {
                "status": status,
                "updated_at": datetime.utcnow().isoformat()
            }

            if notes:
                update_data["notes"] = notes

            self.client.table("appointments") \
                .update(update_data) \
                .eq("ghl_appointment_id", ghl_appointment_id) \
                .execute()

            logger.info(f"Updated appointment status: {ghl_appointment_id} -> {status}")

        except Exception as e:
            logger.error(f"Failed to update appointment: {e}")

    async def update_daily_metrics(self, date: str, metrics: Dict[str, Any]):
        """
        Update daily metrics (background task)

        Args:
            date: Date in YYYY-MM-DD format
            metrics: Metrics to update/increment
                - total_calls: Increment by 1
                - appointments_booked: Increment by 1
                - transfers: Increment by 1
                - avg_call_duration: Update average
                - conversion_rate: Recalculate
        """
        try:
            # Get existing metrics
            result = self.client.table("daily_metrics") \
                .select("*") \
                .eq("date", date) \
                .limit(1) \
                .execute()

            if result.data:
                # Update existing
                existing = result.data[0]

                # Increment counters
                for key in ["total_calls", "appointments_booked", "transfers"]:
                    if key in metrics:
                        existing[key] = existing.get(key, 0) + metrics[key]

                # Update averages
                if "avg_call_duration" in metrics:
                    existing["avg_call_duration"] = metrics["avg_call_duration"]

                # Recalculate conversion rate
                if existing.get("total_calls", 0) > 0:
                    existing["conversion_rate"] = round(
                        (existing.get("appointments_booked", 0) / existing["total_calls"]) * 100,
                        2
                    )

                existing["updated_at"] = datetime.utcnow().isoformat()

                self.client.table("daily_metrics") \
                    .update(existing) \
                    .eq("date", date) \
                    .execute()

            else:
                # Create new
                new_metrics = {
                    "date": date,
                    "total_calls": metrics.get("total_calls", 0),
                    "appointments_booked": metrics.get("appointments_booked", 0),
                    "transfers": metrics.get("transfers", 0),
                    "avg_call_duration": metrics.get("avg_call_duration", 0),
                    "conversion_rate": 0,
                    "created_at": datetime.utcnow().isoformat(),
                    "updated_at": datetime.utcnow().isoformat()
                }

                self.client.table("daily_metrics").insert(new_metrics).execute()

            logger.info(f"Updated metrics for {date}")

        except Exception as e:
            logger.error(f"Failed to update metrics: {e}")

    # ----- ANALYTICS QUERIES -----

    async def get_contact_call_history(
        self,
        phone: str,
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """
        Get call history for a contact

        Args:
            phone: Phone number
            limit: Max number of calls to return

        Returns:
            List of call records
        """
        try:
            result = self.client.table("call_logs") \
                .select("*") \
                .eq("phone_number", phone) \
                .order("call_started_at", desc=True) \
                .limit(limit) \
                .execute()

            return result.data

        except Exception as e:
            logger.error(f"Error fetching call history: {e}")
            return []

    async def get_daily_metrics(self, date: str) -> Optional[Dict[str, Any]]:
        """
        Get metrics for a specific date

        Args:
            date: Date in YYYY-MM-DD format

        Returns:
            Metrics dict or None
        """
        try:
            result = self.client.table("daily_metrics") \
                .select("*") \
                .eq("date", date) \
                .limit(1) \
                .execute()

            if result.data:
                return result.data[0]

            return None

        except Exception as e:
            logger.error(f"Error fetching metrics: {e}")
            return None


def create_supabase_client(
    supabase_url: Optional[str] = None,
    supabase_key: Optional[str] = None
) -> Optional[SupabaseClient]:
    """
    Factory function to create Supabase client

    Args:
        supabase_url: Supabase URL (defaults to SUPABASE_URL env var)
        supabase_key: Supabase key (defaults to SUPABASE_KEY env var)

    Returns:
        SupabaseClient instance or None if not configured
    """
    supabase_url = supabase_url or os.getenv("SUPABASE_URL")
    supabase_key = supabase_key or os.getenv("SUPABASE_KEY")

    if not supabase_url or not supabase_key:
        logger.warning("Supabase not configured (missing URL or KEY)")
        return None

    try:
        return SupabaseClient(supabase_url, supabase_key)
    except Exception as e:
        logger.error(f"Failed to create Supabase client: {e}")
        return None
