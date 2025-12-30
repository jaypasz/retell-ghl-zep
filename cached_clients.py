"""
Optimized clients with multi-layer caching for voice AI
Implements strategies from DATA_LAYER_OPTIMIZATION.md
"""
import json
import time
import logging
from typing import Optional, Dict, Any
from datetime import datetime, timedelta, date
import redis.asyncio as redis

logger = logging.getLogger(__name__)


class CachedMemoryClient:
    """
    Multi-layer memory retrieval with Redis caching

    Strategy:
    1. Redis cache (fast, 5-10ms)
    2. Zep API (slow, 150ms)

    Cache TTL: 5 minutes (300 seconds)
    """

    def __init__(self, zep_client, redis_client):
        self.zep = zep_client
        self.redis = redis_client
        self.cache_ttl = 300  # 5 minutes

    async def get_memory(
        self,
        user_id: str,
        session_id: Optional[str] = None,
        force_refresh: bool = False
    ) -> Dict[str, Any]:
        """
        Get customer memory with caching

        Args:
            user_id: Normalized phone number
            session_id: Optional session ID for session-specific memory
            force_refresh: Force bypass cache and fetch from Zep

        Returns:
            Memory data dict
        """
        cache_key = f"memory:{user_id}"

        # Layer 1: Try Redis cache
        if not force_refresh:
            try:
                cached = await self.redis.get(cache_key)
                if cached:
                    logger.debug(f"Memory cache HIT for {user_id}")
                    return json.loads(cached)
            except Exception as e:
                logger.warning(f"Redis cache read failed: {e}")

        # Layer 2: Fetch from Zep
        logger.debug(f"Memory cache MISS for {user_id}")
        start = time.time()

        memory = await self.zep.get_user_memory(
            user_id=user_id,
            session_id=session_id
        )

        latency = (time.time() - start) * 1000
        logger.info(f"Zep query: {latency:.0f}ms")

        # Cache for next time
        try:
            await self.redis.setex(
                cache_key,
                self.cache_ttl,
                json.dumps(memory)
            )
        except Exception as e:
            logger.warning(f"Redis cache write failed: {e}")

        return memory

    async def invalidate_cache(self, user_id: str):
        """
        Invalidate cache for a user (call after memory updates)

        Args:
            user_id: User ID to invalidate
        """
        try:
            cache_key = f"memory:{user_id}"
            await self.redis.delete(cache_key)
            logger.info(f"Memory cache invalidated for {user_id}")
        except Exception as e:
            logger.warning(f"Cache invalidation failed: {e}")


class CachedCalendarClient:
    """
    Calendar client with aggressive caching

    Strategy:
    - Cache calendar slots for 3 minutes
    - Invalidate cache when slots are booked
    - Include date in cache key for daily invalidation

    Cache TTL: 3 minutes (180 seconds)
    """

    def __init__(self, ghl_client, redis_client):
        self.ghl = ghl_client
        self.redis = redis_client
        self.cache_ttl = 180  # 3 minutes (shorter TTL for real-time data)

    async def get_available_slots(
        self,
        calendar_id: str,
        start_date: str,
        end_date: str,
        timezone: str = "America/New_York",
        force_refresh: bool = False
    ) -> Dict[str, Any]:
        """
        Get available slots with caching

        Args:
            calendar_id: GHL calendar ID
            start_date: Start date (YYYY-MM-DD)
            end_date: End date (YYYY-MM-DD)
            timezone: Timezone string
            force_refresh: Force bypass cache

        Returns:
            Slots data dict
        """
        # Cache key includes date for daily invalidation
        cache_key = f"slots:{calendar_id}:{start_date}:{end_date}:{timezone}"

        # Try cache
        if not force_refresh:
            try:
                cached = await self.redis.get(cache_key)
                if cached:
                    logger.debug(f"Calendar cache HIT for {calendar_id}")
                    return json.loads(cached)
            except Exception as e:
                logger.warning(f"Redis cache read failed: {e}")

        # Fetch from GHL
        logger.debug(f"Calendar cache MISS for {calendar_id}")
        start = time.time()

        slots = await self.ghl.get_available_slots(
            calendar_id=calendar_id,
            start_date=start_date,
            end_date=end_date,
            timezone=timezone
        )

        latency = (time.time() - start) * 1000
        logger.info(f"Calendar query: {latency:.0f}ms")

        # Cache
        try:
            await self.redis.setex(
                cache_key,
                self.cache_ttl,
                json.dumps(slots)
            )
        except Exception as e:
            logger.warning(f"Redis cache write failed: {e}")

        return slots

    async def invalidate_slot(self, calendar_id: str):
        """
        Invalidate cache when slot is booked

        Args:
            calendar_id: Calendar ID to invalidate
        """
        try:
            # Delete cache for all date ranges for this calendar
            pattern = f"slots:{calendar_id}:*"

            # Scan for matching keys
            cursor = 0
            deleted_count = 0
            while True:
                cursor, keys = await self.redis.scan(cursor, match=pattern, count=100)
                if keys:
                    await self.redis.delete(*keys)
                    deleted_count += len(keys)
                if cursor == 0:
                    break

            logger.info(f"Invalidated {deleted_count} calendar cache entries for {calendar_id}")
        except Exception as e:
            logger.warning(f"Cache invalidation failed: {e}")


class ContextCache:
    """
    Full context caching for ultra-fast webhook responses

    Strategy:
    - Cache entire context object (customer + memory + slots + prompt)
    - First call: ~85ms (cache miss)
    - Subsequent calls: ~30ms (cache hit)
    - Background refresh keeps cache warm

    Cache TTL: 5 minutes (300 seconds)
    """

    def __init__(self, redis_client):
        self.redis = redis_client
        self.cache_ttl = 300  # 5 minutes

    async def get_context(self, phone: str) -> Optional[Dict[str, Any]]:
        """
        Get full cached context for a phone number

        Args:
            phone: Normalized phone number

        Returns:
            Context dict or None if cache miss
        """
        cache_key = f"context:{phone}"

        try:
            cached = await self.redis.get(cache_key)
            if cached:
                logger.info(f"Full context cache HIT for {phone}")
                return json.loads(cached)
        except Exception as e:
            logger.warning(f"Context cache read failed: {e}")

        logger.info(f"Context cache MISS for {phone}")
        return None

    async def set_context(
        self,
        phone: str,
        context: Dict[str, Any],
        ttl: Optional[int] = None
    ):
        """
        Cache full context for a phone number

        Args:
            phone: Normalized phone number
            context: Context data to cache
            ttl: Optional custom TTL (defaults to 5 minutes)
        """
        cache_key = f"context:{phone}"
        ttl = ttl or self.cache_ttl

        try:
            await self.redis.setex(
                cache_key,
                ttl,
                json.dumps(context)
            )
            logger.debug(f"Cached context for {phone} (TTL: {ttl}s)")
        except Exception as e:
            logger.warning(f"Context cache write failed: {e}")

    async def invalidate_context(self, phone: str):
        """
        Invalidate cached context

        Args:
            phone: Phone number to invalidate
        """
        try:
            cache_key = f"context:{phone}"
            await self.redis.delete(cache_key)
            logger.info(f"Context cache invalidated for {phone}")
        except Exception as e:
            logger.warning(f"Context invalidation failed: {e}")


async def create_redis_client(redis_url: str = "redis://localhost:6379") -> redis.Redis:
    """
    Create Redis client with proper configuration

    Args:
        redis_url: Redis connection URL

    Returns:
        Configured Redis client
    """
    try:
        client = redis.from_url(
            redis_url,
            encoding="utf-8",
            decode_responses=True,
            socket_connect_timeout=5,
            socket_timeout=5,
            retry_on_timeout=True,
            health_check_interval=30
        )

        # Test connection
        await client.ping()
        logger.info(f"Redis connected successfully: {redis_url}")

        return client

    except Exception as e:
        logger.error(f"Failed to connect to Redis: {e}")
        raise
