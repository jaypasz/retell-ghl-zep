"""
Test script for Retell inbound endpoint and appointment booking
Usage: python test_endpoint.py
"""
import asyncio
import httpx
from datetime import datetime, timedelta

BASE_URL = "http://localhost:8000"

async def test_health():
    """Test health endpoint"""
    print("\n=== Testing Health Endpoint ===")
    async with httpx.AsyncClient() as client:
        response = await client.get(f"{BASE_URL}/health")
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")

async def test_inbound_webhook():
    """Test Retell inbound webhook"""
    print("\n=== Testing Retell Inbound Webhook ===")
    
    test_payload = {
        "call_id": "test-call-123",
        "from_number": "+15551234567",
        "to_number": "+15559876543",
        "direction": "inbound",
        "metadata": {
            "source": "test",
            "campaign": "demo"
        }
    }
    
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            f"{BASE_URL}/retell/inbound",
            json=test_payload
        )
        print(f"Status: {response.status_code}")
        result = response.json()
        print(f"Response: {result}")
        
        # Check for appointment data
        dynamic_vars = result.get("dynamic_variables", {})
        if "available_slots" in dynamic_vars:
            print(f"\n✅ Found {len(dynamic_vars['available_slots'])} available slots")
        if "existing_appointments" in dynamic_vars:
            print(f"✅ Found {len(dynamic_vars['existing_appointments'])} existing appointments")
        
        return result

async def test_get_availability():
    """Test getting available appointment slots"""
    print("\n=== Testing Get Availability ===")
    
    start_date = datetime.now().strftime("%Y-%m-%d")
    end_date = (datetime.now() + timedelta(days=7)).strftime("%Y-%m-%d")
    
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.get(
            f"{BASE_URL}/appointments/availability",
            params={
                "start_date": start_date,
                "end_date": end_date
            }
        )
        print(f"Status: {response.status_code}")
        result = response.json()
        print(f"Available slots: {len(result.get('slots', []))}")
        if result.get('slots'):
            print(f"First few slots: {result['slots'][:3]}")
        return result

async def test_book_appointment():
    """Test booking an appointment"""
    print("\n=== Testing Book Appointment ===")
    
    # Use a future time slot
    future_time = (datetime.now() + timedelta(days=1)).replace(hour=14, minute=0, second=0, microsecond=0)
    slot_time = future_time.strftime("%Y-%m-%dT%H:%M:%S") + "Z"
    
    test_payload = {
        "customer_phone": "+15551234567",
        "slot_time": slot_time,
        "title": "Test Consultation",
        "notes": "Automated test booking"
    }
    
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            f"{BASE_URL}/appointments/book",
            json=test_payload
        )
        print(f"Status: {response.status_code}")
        result = response.json()
        print(f"Response: {result}")
        
        if result.get("success"):
            print(f"✅ Appointment booked successfully!")
            return result.get("appointment", {}).get("id")
        else:
            print(f"❌ Booking failed: {result}")
            return None

async def test_reschedule_appointment(event_id):
    """Test rescheduling an appointment"""
    print("\n=== Testing Reschedule Appointment ===")
    
    if not event_id:
        print("⚠️  Skipping reschedule test - no event_id provided")
        return
    
    # Reschedule to one day later
    new_time = (datetime.now() + timedelta(days=2)).replace(hour=15, minute=0, second=0, microsecond=0)
    new_start_time = new_time.strftime("%Y-%m-%dT%H:%M:%S") + "Z"
    
    test_payload = {
        "event_id": event_id,
        "new_start_time": new_start_time
    }
    
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            f"{BASE_URL}/appointments/reschedule",
            json=test_payload
        )
        print(f"Status: {response.status_code}")
        result = response.json()
        print(f"Response: {result}")
        
        if result.get("success"):
            print(f"✅ Appointment rescheduled successfully!")
        return result

async def test_cancel_appointment(event_id):
    """Test cancelling an appointment"""
    print("\n=== Testing Cancel Appointment ===")
    
    if not event_id:
        print("⚠️  Skipping cancel test - no event_id provided")
        return
    
    test_payload = {
        "event_id": event_id
    }
    
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            f"{BASE_URL}/appointments/cancel",
            json=test_payload
        )
        print(f"Status: {response.status_code}")
        result = response.json()
        print(f"Response: {result}")
        
        if result.get("success"):
            print(f"✅ Appointment cancelled successfully!")
        return result

async def test_call_ended():
    """Test call ended webhook"""
    print("\n=== Testing Call Ended Webhook ===")
    
    test_payload = {
        "call_id": "test-call-123",
        "from_number": "+15551234567",
        "to_number": "+15559876543",
        "transcript": "Customer: Hi, I'd like to make an appointment.\nAgent: Of course! What day works best for you?\nCustomer: How about next Tuesday?\nAgent: Tuesday at 2pm works. See you then!",
        "duration": 45,
        "call_status": "completed"
    }
    
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            f"{BASE_URL}/retell/call-ended",
            json=test_payload
        )
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")

async def main():
    """Run all tests"""
    print("=" * 70)
    print("RETELL-ZEP-GHL INTEGRATION TEST SUITE")
    print("=" * 70)
    
    try:
        # Basic tests
        await test_health()
        inbound_result = await test_inbound_webhook()
        
        # Appointment tests
        await test_get_availability()
        
        # Full booking flow (only if GHL is configured)
        print("\n" + "=" * 70)
        print("TESTING APPOINTMENT BOOKING FLOW")
        print("=" * 70)
        
        event_id = await test_book_appointment()
        
        if event_id:
            await asyncio.sleep(2)  # Wait a bit between operations
            await test_reschedule_appointment(event_id)
            await asyncio.sleep(2)
            await test_cancel_appointment(event_id)
        else:
            print("\n⚠️  Skipping reschedule/cancel tests - booking failed or GHL not configured")
        
        # Transcript storage
        await test_call_ended()
        
        print("\n" + "=" * 70)
        print("✅ All tests completed!")
        print("=" * 70)
        
    except Exception as e:
        print(f"\n❌ Error: {str(e)}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    print("Starting tests...")
    print("Make sure the server is running: uvicorn main:app --reload")
    print()
    asyncio.run(main())
